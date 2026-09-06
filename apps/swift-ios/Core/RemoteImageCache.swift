import Foundation

/// One session for every remote image the transcript renders, backed by a disk
/// cache so reopening a thread does not download its pictures again.
///
/// Attachment and markdown image URLs address immutable content, so a cached
/// response is always still correct — hence `returnCacheDataElseLoad` rather
/// than a revalidating policy that would round-trip on every open just to be
/// told nothing changed. Cookies and credentials stay off, as they were when
/// this used an ephemeral session.
enum RemoteImageCache {
    private static let directory: URL? = {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }
        return base
            .appendingPathComponent("T3CodeSwift", isDirectory: true)
            .appendingPathComponent("image-cache", isDirectory: true)
    }()

    private static let urlCache: URLCache = {
        URLCache(
            memoryCapacity: 16 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024,
            directory: directory
        )
    }()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    static var sizeOnDisk: Int64 {
        Int64(urlCache.currentDiskUsage)
    }

    static func clear() {
        urlCache.removeAllCachedResponses()
    }
}
