import Foundation
import Testing
@testable import T3Code

@Suite("Thread store")
struct ThreadStoreTests {
    private func makeStore() -> ThreadStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thread-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("threads.sqlite")
        return ThreadStore(fileURL: url)
    }

    private func thread(_ id: String = "thread-1") -> FeatureThread {
        FeatureThread(id: id, projectID: "project-1", environmentID: "env-1", title: "Test")
    }

    private func message(_ id: String, _ text: String) -> FeatureMessage {
        FeatureMessage(id: id, role: .assistant, text: text)
    }

    private func wireThread(id: String = "wire-1") -> OrchestrationThread {
        OrchestrationThread(
            id: id,
            projectId: "project-1",
            title: "Test",
            modelSelection: ModelSelection(instanceId: "codex", model: "gpt-5.6-sol"),
            runtimeMode: .fullAccess,
            interactionMode: .default,
            branch: nil,
            worktreePath: nil,
            latestTurn: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            archivedAt: nil,
            settledOverride: nil,
            settledAt: nil,
            snoozedUntil: nil,
            snoozedAt: nil,
            pinnedAt: nil,
            deletedAt: nil,
            messages: [],
            activities: [],
            checkpoints: [],
            session: nil
        )
    }

    @Test
    func anUnvisitedThreadReadsAsMissingRatherThanEmpty() async {
        let store = makeStore()

        #expect(await store.loadThread(environmentID: "env-1", threadID: "thread-1") == nil)
    }

    @Test
    func storedMessagesComeBackInTheOrderTheyWereWritten() async {
        let store = makeStore()
        let detail = FeatureThreadDetail(
            thread: thread(),
            messages: [message("a", "first"), message("b", "second"), message("c", "third")]
        )

        await store.replace(detail, environmentID: "env-1", sequence: 7)
        let stored = await store.loadThread(environmentID: "env-1", threadID: "thread-1")

        #expect(stored?.messages.map(\.id) == ["a", "b", "c"])
        #expect(stored?.sequence == 7)
    }

    /// A snapshot is authoritative: messages the server no longer lists have to
    /// disappear locally too, or a deleted turn would live on forever on device.
    @Test
    func replacingDropsMessagesTheServerNoLongerHas() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: [message("a", "first"), message("b", "second")]
            ),
            environmentID: "env-1",
            sequence: 1
        )

        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [message("a", "first")]),
            environmentID: "env-1",
            sequence: 2
        )
        let stored = await store.loadThread(environmentID: "env-1", threadID: "thread-1")

        #expect(stored?.messages.map(\.id) == ["a"])
    }

    /// Streaming edits the same message repeatedly. Each edit must land in place
    /// rather than appending a second copy at the end of the transcript.
    @Test
    func mergingEditsInPlaceAndAppendsOnlyWhatIsNew() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: [message("a", "first"), message("b", "partial")]
            ),
            environmentID: "env-1",
            sequence: 1
        )

        await store.merge(
            changedMessages: [message("b", "complete"), message("c", "new")],
            thread: thread(),
            environmentID: "env-1",
            sequence: 5,
            page: nil
        )
        let stored = await store.loadThread(environmentID: "env-1", threadID: "thread-1")

        #expect(stored?.messages.map(\.id) == ["a", "b", "c"])
        #expect(stored?.messages.first { $0.id == "b" }?.text == "complete")
        #expect(stored?.sequence == 5)
    }

    /// Scrolling back reads from disk before the network. The window rendered on
    /// open is smaller than what is stored, so the messages just above it are
    /// already local — asking the server for them is a wait for nothing.
    @Test
    func earlierMessagesComeBackFromDiskOldestFirst() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: (1 ... 8).map { message("m\($0)", "text \($0)") }
            ),
            environmentID: "env-1",
            sequence: 1
        )

        let older = await store.messages(
            before: "m5",
            environmentID: "env-1",
            threadID: "thread-1",
            limit: 3
        )

        #expect(older.map(\.id) == ["m2", "m3", "m4"])
    }

    /// The oldest message on disk has nothing before it, and the empty result is
    /// what tells the caller to fall through to the server.
    @Test
    func reachingTheStartOfStoredHistoryReadsAsEmpty() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: [message("a", "first"), message("b", "second")]
            ),
            environmentID: "env-1",
            sequence: 1
        )

        let older = await store.messages(
            before: "a",
            environmentID: "env-1",
            threadID: "thread-1",
            limit: 10
        )

        #expect(older.isEmpty)
    }

    /// Opening a thread renders a recent window, not its entire history — but it
    /// has to be the *newest* window, still in reading order.
    @Test
    func aLimitedReadReturnsTheNewestMessagesOldestFirst() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: (1 ... 6).map { message("m\($0)", "text \($0)") }
            ),
            environmentID: "env-1",
            sequence: 1
        )

        let stored = await store.loadThread(
            environmentID: "env-1",
            threadID: "thread-1",
            limit: 3
        )

        #expect(stored?.messages.map(\.id) == ["m4", "m5", "m6"])
    }

    /// Optimistic preview bytes can be megabytes per attachment and belong to the
    /// send that produced them; a restored message renders from the server URL.
    @Test
    func optimisticPreviewBytesAreNotPersisted() async {
        let store = makeStore()
        var attachment = FeatureMessageAttachment(
            id: "attachment-1",
            name: "photo.png",
            mimeType: "image/png",
            sizeBytes: 4
        )
        attachment.previewData = Data([0, 1, 2, 3])
        var sent = message("a", "with attachment")
        sent.attachments = [attachment]

        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [sent]),
            environmentID: "env-1",
            sequence: 1
        )
        let stored = await store.loadThread(environmentID: "env-1", threadID: "thread-1")

        #expect(stored?.messages.first?.attachments.first?.previewData == nil)
        #expect(stored?.messages.first?.attachments.first?.name == "photo.png")
    }

    /// Settled threads keep a recent window rather than their whole history.
    /// The page cursor survives, so scrolling back can still fetch what was
    /// dropped instead of hitting a dead end.
    @Test
    func pruningKeepsTheNewestWindowAndLeavesTheCursorIntact() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: (1 ... 10).map { message("m\($0)", "text \($0)") },
                page: FeatureThreadPage(beforeCursor: "cursor-1", hasMore: true)
            ),
            environmentID: "env-1",
            sequence: 1
        )

        await store.prune(environmentID: "env-1", threadID: "thread-1", keeping: 3)
        let stored = await store.loadThread(environmentID: "env-1", threadID: "thread-1")

        #expect(stored?.messages.map(\.id) == ["m8", "m9", "m10"])
        #expect(stored?.page?.beforeCursor == "cursor-1")
        #expect(stored?.page?.hasMore == true)
    }

    /// Pruning a thread shorter than the window must not empty it.
    @Test
    func pruningAShortThreadKeepsEverything() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: [message("a", "first"), message("b", "second")]
            ),
            environmentID: "env-1",
            sequence: 1
        )

        await store.prune(environmentID: "env-1", threadID: "thread-1", keeping: 25)
        let stored = await store.loadThread(environmentID: "env-1", threadID: "thread-1")

        #expect(stored?.messages.map(\.id) == ["a", "b"])
    }

    /// The settings screen reports this number, and reporting zero for a store
    /// that holds conversations would read as a bug.
    @Test
    func storedHistoryReportsItsSizeOnDisk() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(
                thread: thread(),
                messages: (1 ... 20).map { message("m\($0)", String(repeating: "text ", count: 40)) }
            ),
            environmentID: "env-1",
            sequence: 1
        )

        #expect(await store.sizeOnDisk() > 0)
    }

    @Test
    func clearingHistoryLeavesNoThreadsBehind() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [message("a", "first")]),
            environmentID: "env-1",
            sequence: 1
        )

        await store.clearAll()

        #expect(await store.loadThread(environmentID: "env-1", threadID: "thread-1") == nil)
    }

    @Test
    func signingOutOfAnEnvironmentLeavesNothingBehind() async {
        let store = makeStore()
        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [message("a", "first")]),
            environmentID: "env-1",
            sequence: 1
        )
        await store.replace(
            FeatureThreadDetail(thread: thread("thread-2"), messages: [message("b", "kept")]),
            environmentID: "env-2",
            sequence: 1
        )

        await store.clearEnvironment("env-1")

        #expect(await store.loadThread(environmentID: "env-1", threadID: "thread-1") == nil)
        #expect(await store.loadThread(environmentID: "env-2", threadID: "thread-2") != nil)
    }

    /// Resuming a subscription replays events into the reducer, which works on
    /// the server's own thread representation rather than the mapped one. Without
    /// it the stream has no base to apply events to and falls back to a full
    /// refresh, which is the round trip the store exists to avoid.
    @Test
    func theServerRepresentationSurvivesSoAStreamCanResume() async {
        let store = makeStore()
        let raw = wireThread()

        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [message("a", "first")]),
            environmentID: "env-1",
            sequence: 3,
            raw: raw
        )

        #expect(
            await store.loadRawThread(environmentID: "env-1", threadID: "thread-1")?.id == "wire-1"
        )
    }

    /// A delta carries no raw thread of its own. Overwriting with nil would
    /// strand the thread on its next launch — able to render, unable to resume.
    @Test
    func aDeltaDoesNotEraseTheStoredServerRepresentation() async {
        let store = makeStore()
        let raw = wireThread()
        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [message("a", "first")]),
            environmentID: "env-1",
            sequence: 3,
            raw: raw
        )

        await store.merge(
            changedMessages: [message("b", "second")],
            thread: thread(),
            environmentID: "env-1",
            sequence: 4,
            page: nil,
            raw: nil
        )

        #expect(
            await store.loadRawThread(environmentID: "env-1", threadID: "thread-1")?.id == "wire-1"
        )
    }

    @Test
    func aStoredSequenceIsWhatTheStreamResumesFrom() async {
        let store = makeStore()

        #expect(await store.storedSequence(environmentID: "env-1", threadID: "thread-1") == nil)
        await store.replace(
            FeatureThreadDetail(thread: thread(), messages: [message("a", "first")]),
            environmentID: "env-1",
            sequence: 42
        )

        #expect(await store.storedSequence(environmentID: "env-1", threadID: "thread-1") == 42)
    }
}
