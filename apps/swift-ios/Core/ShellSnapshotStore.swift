import Foundation

/// The last thread list seen, kept on disk so a cold launch can show the home
/// screen before the network answers.
///
/// One small document rather than a table: it is rewritten whole every time and
/// read once at launch, which is exactly what the other stores in this app do.
actor ShellSnapshotStore {
    private struct Document: Codable {
        var version = 1
        var snapshot: FeatureSnapshot
    }

    private let fileURL: URL
    private var cached: FeatureSnapshot?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("T3CodeSwift", isDirectory: true)
            .appendingPathComponent("shell-snapshot.json", isDirectory: false)
    }

    func snapshot() -> FeatureSnapshot? {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder.t3.decode(Document.self, from: data) else {
            return nil
        }
        cached = document.snapshot
        return document.snapshot
    }

    func save(_ snapshot: FeatureSnapshot) {
        guard cached != snapshot else { return }
        cached = snapshot
        guard let data = try? JSONEncoder.t3.encode(Document(snapshot: snapshot)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        cached = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
