import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// On-disk thread history. Opening a thread reads from here, so the network is
/// a reconciliation step rather than something the reader waits on.
///
/// SQLite rather than the JSON documents the other stores use: history is kept
/// in full, and appending one streamed message to a JSON document would rewrite
/// the entire transcript several times a second while an agent is working.
actor ThreadStore {
    /// What a thread looked like when it was last persisted. Approvals and
    /// user inputs are deliberately absent: they are live negotiation state and
    /// restoring a stale one would show a prompt the server no longer expects.
    struct StoredThread: Sendable, Equatable {
        var thread: FeatureThread
        var messages: [FeatureMessage]
        var page: FeatureThreadPage?
        var sequence: Int
    }

    /// Schema revisions. Bumped rather than recreated so a device that already
    /// has history keeps it.
    private static let schemaVersion = 2

    enum StoreError: Error {
        case open(String)
        case statement(String)
    }

    private let fileURL: URL
    private var handle: OpaquePointer?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("T3CodeSwift", isDirectory: true)
            .appendingPathComponent("threads.sqlite", isDirectory: false)
    }

    // MARK: - Connection

    private func database() throws -> OpaquePointer {
        if let handle { return handle }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(fileURL.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(opened)
            throw StoreError.open(message)
        }
        handle = opened
        try migrate(opened)
        return opened
    }

    private func migrate(_ database: OpaquePointer) throws {
        try execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS thread (
                environment_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                payload BLOB NOT NULL,
                sequence INTEGER NOT NULL,
                before_cursor TEXT,
                has_more INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (environment_id, thread_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS message (
                environment_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (environment_id, thread_id, message_id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS message_thread_ordinal
                ON message (environment_id, thread_id, ordinal);
            """,
            on: database
        )
        if userVersion(on: database) < 2 {
            // The reducer applies streamed events to the wire thread, not the
            // mapped one, so resuming a subscription from disk needs the server's
            // own representation kept alongside.
            try? execute("ALTER TABLE thread ADD COLUMN raw_payload BLOB", on: database)
            try? execute("PRAGMA user_version = 2", on: database)
        }
    }

    private func userVersion(on database: OpaquePointer) -> Int {
        guard let statement = try? prepare("PRAGMA user_version", on: database) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.statement(message)
        }
    }

    private func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.statement(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    }

    private func bind(_ data: Data, at index: Int32, to statement: OpaquePointer) {
        data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), sqliteTransient)
        }
    }

    // MARK: - Reading

    /// The most recent `limit` messages, returned oldest-first so the caller can
    /// render them directly. `nil` when the thread has never been stored, which
    /// is the caller's signal that it has to go to the network.
    func loadThread(
        environmentID: String,
        threadID: String,
        limit: Int? = nil
    ) -> StoredThread? {
        guard let database = try? database() else { return nil }
        guard let header = try? prepare(
            """
            SELECT payload, sequence, before_cursor, has_more
            FROM thread WHERE environment_id = ? AND thread_id = ?
            """,
            on: database
        ) else { return nil }
        defer { sqlite3_finalize(header) }
        bind(environmentID, at: 1, to: header)
        bind(threadID, at: 2, to: header)
        guard sqlite3_step(header) == SQLITE_ROW,
              let threadBytes = sqlite3_column_blob(header, 0) else { return nil }
        let threadData = Data(bytes: threadBytes, count: Int(sqlite3_column_bytes(header, 0)))
        guard let thread = try? JSONDecoder.t3.decode(FeatureThread.self, from: threadData) else {
            return nil
        }
        let sequence = Int(sqlite3_column_int64(header, 1))
        let beforeCursor = sqlite3_column_text(header, 2).map { String(cString: $0) }
        let hasMore = sqlite3_column_int64(header, 3) != 0

        let sql = limit == nil
            ? """
              SELECT payload FROM message
              WHERE environment_id = ? AND thread_id = ?
              ORDER BY ordinal ASC
              """
            : """
              SELECT payload FROM (
                  SELECT payload, ordinal FROM message
                  WHERE environment_id = ? AND thread_id = ?
                  ORDER BY ordinal DESC LIMIT ?
              ) ORDER BY ordinal ASC
              """
        guard let rows = try? prepare(sql, on: database) else { return nil }
        defer { sqlite3_finalize(rows) }
        bind(environmentID, at: 1, to: rows)
        bind(threadID, at: 2, to: rows)
        if let limit {
            sqlite3_bind_int64(rows, 3, Int64(limit))
        }
        var messages: [FeatureMessage] = []
        while sqlite3_step(rows) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(rows, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(rows, 0)))
            if let message = try? JSONDecoder.t3.decode(FeatureMessage.self, from: data) {
                messages.append(message)
            }
        }
        return StoredThread(
            thread: thread,
            messages: messages,
            page: FeatureThreadPage(beforeCursor: beforeCursor, hasMore: hasMore),
            sequence: sequence
        )
    }

    /// Messages immediately older than `messageID`, oldest-first.
    ///
    /// Empty when disk has nothing older, which is the caller's signal to ask
    /// the server. Turns are not a stored unit — the store only knows messages —
    /// so callers ask for a message count that approximates a page.
    func messages(
        before messageID: String,
        environmentID: String,
        threadID: String,
        limit: Int
    ) -> [FeatureMessage] {
        guard let database = try? database(),
              let cutoff = ordinal(
                  environmentID: environmentID,
                  threadID: threadID,
                  messageID: messageID,
                  on: database
              ),
              let statement = try? prepare(
                  """
                  SELECT payload FROM (
                      SELECT payload, ordinal FROM message
                      WHERE environment_id = ? AND thread_id = ? AND ordinal < ?
                      ORDER BY ordinal DESC LIMIT ?
                  ) ORDER BY ordinal ASC
                  """,
                  on: database
              ) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        sqlite3_bind_int64(statement, 3, Int64(cutoff))
        sqlite3_bind_int64(statement, 4, Int64(limit))
        var messages: [FeatureMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if let message = try? JSONDecoder.t3.decode(FeatureMessage.self, from: data) {
                messages.append(message)
            }
        }
        return messages
    }

    /// The server's own representation of the thread, which the reducer needs
    /// as its base before it can apply replayed events.
    func loadRawThread(environmentID: String, threadID: String) -> OrchestrationThread? {
        guard let database = try? database(),
              let statement = try? prepare(
                  "SELECT raw_payload FROM thread WHERE environment_id = ? AND thread_id = ?",
                  on: database
              ) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try? JSONDecoder.t3.decode(OrchestrationThread.self, from: data)
    }

    /// The sequence the stream should resume from. The server replays events
    /// after it, or sends a fresh snapshot when the gap is too wide.
    func storedSequence(environmentID: String, threadID: String) -> Int? {
        guard let database = try? database(),
              let statement = try? prepare(
                  "SELECT sequence FROM thread WHERE environment_id = ? AND thread_id = ?",
                  on: database
              ) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Writing

    /// Replaces a thread wholesale. Used for snapshots, where the server's list
    /// is authoritative and messages may have been removed as well as added.
    func replace(
        _ detail: FeatureThreadDetail,
        environmentID: String,
        sequence: Int,
        raw: OrchestrationThread? = nil
    ) {
        guard let database = try? database() else { return }
        try? execute("BEGIN IMMEDIATE", on: database)
        writeHeader(
            detail,
            environmentID: environmentID,
            sequence: sequence,
            raw: raw,
            on: database
        )
        if let purge = try? prepare(
            "DELETE FROM message WHERE environment_id = ? AND thread_id = ?",
            on: database
        ) {
            bind(environmentID, at: 1, to: purge)
            bind(detail.thread.id, at: 2, to: purge)
            sqlite3_step(purge)
            sqlite3_finalize(purge)
        }
        write(
            detail.messages.enumerated().map { ($0.offset, $0.element) },
            environmentID: environmentID,
            threadID: detail.thread.id,
            on: database
        )
        try? execute("COMMIT", on: database)
    }

    /// Applies a streamed delta. Existing messages keep their position; new ones
    /// are appended after the highest ordinal already stored.
    func merge(
        changedMessages: [FeatureMessage],
        thread: FeatureThread,
        environmentID: String,
        sequence: Int,
        page: FeatureThreadPage?,
        raw: OrchestrationThread? = nil
    ) {
        guard !changedMessages.isEmpty || sequence > 0,
              let database = try? database() else { return }
        try? execute("BEGIN IMMEDIATE", on: database)
        writeHeader(
            FeatureThreadDetail(thread: thread, page: page),
            environmentID: environmentID,
            sequence: sequence,
            raw: raw,
            on: database
        )
        var nextOrdinal = highestOrdinal(
            environmentID: environmentID,
            threadID: thread.id,
            on: database
        ) + 1
        var positioned: [(Int, FeatureMessage)] = []
        for message in changedMessages {
            if let existing = ordinal(
                environmentID: environmentID,
                threadID: thread.id,
                messageID: message.id,
                on: database
            ) {
                positioned.append((existing, message))
            } else {
                positioned.append((nextOrdinal, message))
                nextOrdinal += 1
            }
        }
        write(positioned, environmentID: environmentID, threadID: thread.id, on: database)
        try? execute("COMMIT", on: database)
    }

    /// Older turns fetched by paging backwards. They take negative ordinals so
    /// they sort ahead of what is already stored without renumbering it — a full
    /// history walk would otherwise rewrite the whole thread once per page.
    func prepend(
        messages: [FeatureMessage],
        environmentID: String,
        threadID: String,
        page: FeatureThreadPage?
    ) {
        guard !messages.isEmpty, let database = try? database() else { return }
        try? execute("BEGIN IMMEDIATE", on: database)
        var ordinal = boundary(
            "MIN",
            environmentID: environmentID,
            threadID: threadID,
            fallback: 0,
            on: database
        ) - messages.count
        var positioned: [(Int, FeatureMessage)] = []
        for message in messages {
            positioned.append((ordinal, message))
            ordinal += 1
        }
        write(positioned, environmentID: environmentID, threadID: threadID, on: database)
        if let page, let statement = try? prepare(
            """
            UPDATE thread SET before_cursor = ?, has_more = ?
            WHERE environment_id = ? AND thread_id = ?
            """,
            on: database
        ) {
            if let cursor = page.beforeCursor {
                bind(cursor, at: 1, to: statement)
            } else {
                sqlite3_bind_null(statement, 1)
            }
            sqlite3_bind_int64(statement, 2, page.hasMore ? 1 : 0)
            bind(environmentID, at: 3, to: statement)
            bind(threadID, at: 4, to: statement)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        try? execute("COMMIT", on: database)
    }

    /// Where a history walk should resume from, without reading any messages.
    func storedPage(environmentID: String, threadID: String) -> FeatureThreadPage? {
        guard let database = try? database(),
              let statement = try? prepare(
                  """
                  SELECT before_cursor, has_more FROM thread
                  WHERE environment_id = ? AND thread_id = ?
                  """,
                  on: database
              ) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FeatureThreadPage(
            beforeCursor: sqlite3_column_text(statement, 0).map { String(cString: $0) },
            hasMore: sqlite3_column_int64(statement, 1) != 0
        )
    }

    /// Drops all but the newest `keeping` messages. Full history is worth
    /// keeping while a thread is live; once it settles the older turns are
    /// mostly dead weight, and the cursor is left intact so scrolling back can
    /// still fetch them again on demand.
    func prune(
        environmentID: String,
        threadID: String,
        keeping newest: Int
    ) {
        guard let database = try? database(),
              let statement = try? prepare(
                  """
                  DELETE FROM message
                  WHERE environment_id = ? AND thread_id = ? AND ordinal <= (
                      SELECT ordinal FROM message
                      WHERE environment_id = ? AND thread_id = ?
                      ORDER BY ordinal DESC LIMIT 1 OFFSET ?
                  )
                  """,
                  on: database
              ) else { return }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        bind(environmentID, at: 3, to: statement)
        bind(threadID, at: 4, to: statement)
        sqlite3_bind_int64(statement, 5, Int64(newest))
        sqlite3_step(statement)
    }

    /// Bytes on disk, including the write-ahead log and shared-memory files —
    /// a settings screen that quoted only the main database would understate it
    /// while a thread is streaming.
    func sizeOnDisk() -> Int64 {
        [fileURL, fileURL.appendingPathExtension("wal"), fileURL.appendingPathExtension("shm")]
            .reduce(into: Int64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size ?? 0)
            }
    }

    /// Drops every thread and reclaims the space. The next launch refetches, so
    /// this costs bandwidth rather than data.
    func clearAll() {
        guard let database = try? database() else { return }
        try? execute("DELETE FROM message; DELETE FROM thread;", on: database)
        try? execute("VACUUM", on: database)
    }

    func clearEnvironment(_ environmentID: String) {
        guard let database = try? database() else { return }
        for sql in [
            "DELETE FROM message WHERE environment_id = ?",
            "DELETE FROM thread WHERE environment_id = ?",
        ] {
            guard let statement = try? prepare(sql, on: database) else { continue }
            bind(environmentID, at: 1, to: statement)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    func removeThread(environmentID: String, threadID: String) {
        guard let database = try? database() else { return }
        for sql in [
            "DELETE FROM message WHERE environment_id = ? AND thread_id = ?",
            "DELETE FROM thread WHERE environment_id = ? AND thread_id = ?",
        ] {
            guard let statement = try? prepare(sql, on: database) else { continue }
            bind(environmentID, at: 1, to: statement)
            bind(threadID, at: 2, to: statement)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Row helpers

    private func writeHeader(
        _ detail: FeatureThreadDetail,
        environmentID: String,
        sequence: Int,
        raw: OrchestrationThread?,
        on database: OpaquePointer
    ) {
        guard let payload = try? JSONEncoder.t3.encode(detail.thread),
              let statement = try? prepare(
                  """
                  INSERT INTO thread
                      (environment_id, thread_id, payload, sequence, before_cursor, has_more, updated_at, raw_payload)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT (environment_id, thread_id) DO UPDATE SET
                      payload = excluded.payload,
                      sequence = max(thread.sequence, excluded.sequence),
                      before_cursor = excluded.before_cursor,
                      has_more = excluded.has_more,
                      updated_at = excluded.updated_at,
                      raw_payload = coalesce(excluded.raw_payload, thread.raw_payload)
                  """,
                  on: database
              ) else { return }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(detail.thread.id, at: 2, to: statement)
        bind(payload, at: 3, to: statement)
        sqlite3_bind_int64(statement, 4, Int64(sequence))
        if let cursor = detail.page?.beforeCursor {
            bind(cursor, at: 5, to: statement)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_int64(statement, 6, (detail.page?.hasMore ?? false) ? 1 : 0)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSinceReferenceDate)
        if let raw, let rawPayload = try? JSONEncoder.t3.encode(raw) {
            bind(rawPayload, at: 8, to: statement)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_step(statement)
    }

    private func write(
        _ messages: [(Int, FeatureMessage)],
        environmentID: String,
        threadID: String,
        on database: OpaquePointer
    ) {
        guard let statement = try? prepare(
            """
            INSERT INTO message (environment_id, thread_id, message_id, ordinal, payload)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (environment_id, thread_id, message_id) DO UPDATE SET
                ordinal = excluded.ordinal,
                payload = excluded.payload
            """,
            on: database
        ) else { return }
        defer { sqlite3_finalize(statement) }
        for (ordinal, message) in messages {
            guard let payload = try? JSONEncoder.t3.encode(Self.persistable(message)) else { continue }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(environmentID, at: 1, to: statement)
            bind(threadID, at: 2, to: statement)
            bind(message.id, at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, Int64(ordinal))
            bind(payload, at: 5, to: statement)
            sqlite3_step(statement)
        }
    }

    /// Optimistic preview bytes belong to the send that produced them and can be
    /// several megabytes per attachment. The server-hydrated URL is what a
    /// restored message renders from.
    private static func persistable(_ message: FeatureMessage) -> FeatureMessage {
        guard message.attachments.contains(where: { $0.previewData != nil }) else { return message }
        var copy = message
        copy.attachments = message.attachments.map { attachment in
            var stripped = attachment
            stripped.previewData = nil
            return stripped
        }
        return copy
    }

    private func highestOrdinal(
        environmentID: String,
        threadID: String,
        on database: OpaquePointer
    ) -> Int {
        boundary("MAX", environmentID: environmentID, threadID: threadID, fallback: -1, on: database)
    }

    private func boundary(
        _ function: String,
        environmentID: String,
        threadID: String,
        fallback: Int,
        on database: OpaquePointer
    ) -> Int {
        guard let statement = try? prepare(
            "SELECT \(function)(ordinal) FROM message WHERE environment_id = ? AND thread_id = ?",
            on: database
        ) else { return fallback }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return fallback }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func ordinal(
        environmentID: String,
        threadID: String,
        messageID: String,
        on database: OpaquePointer
    ) -> Int? {
        guard let statement = try? prepare(
            """
            SELECT ordinal FROM message
            WHERE environment_id = ? AND thread_id = ? AND message_id = ?
            """,
            on: database
        ) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(environmentID, at: 1, to: statement)
        bind(threadID, at: 2, to: statement)
        bind(messageID, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
