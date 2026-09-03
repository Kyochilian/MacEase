import AppKit
import Foundation
import NeteaseKit

/// Loads and caches artwork.
///
/// Three things this has to get right, and one it deliberately does not do:
///
/// - **Coalescing.** A list of thirty tracks from one album asks for the same
///   cover thirty times in the same frame. Without this, that is thirty
///   requests for one image.
/// - **Two tiers.** Decoded images live in an `NSCache`, which the system
///   empties under memory pressure on its own. Bytes live in a `URLCache` on
///   disk, so relaunching does not re-download the library's covers.
/// - **A bound.** The disk tier has a ceiling the user can see and clear.
///
/// It never *decides* to fetch. A view asks for a cover it is about to draw,
/// which is the only thing that makes artwork a request the user implied.
///
/// It lives on the main actor rather than in an actor of its own: `NSImage` is
/// not `Sendable`, so a background actor could only ever hand back bytes, and
/// every caller would then decode the same cover again on the main thread. The
/// only genuinely concurrent part — the transfer — is already off-thread
/// inside `URLSession`.
@MainActor
package final class ArtworkLoader {
  /// Cheap for artwork, which is a few tens of kilobytes per cover, and small
  /// enough that the decoded tier is never the reason memory grows.
  private static let memoryCapacityBytes = 32 * 1024 * 1024

  private let urlSession: URLSession
  private let urlCache: URLCache
  private let decoder: @MainActor (Data) async -> NSImage?
  private let decoded = NSCache<NSURL, NSImage>()
  private final class InFlightTask {
    let task: Task<Data?, Never>

    init(_ task: Task<Data?, Never>) { self.task = task }
  }

  private var inFlight: [URL: InFlightTask] = [:]

  package init(
    diskCapacityBytes: Int,
    directory: URL? = ArtworkLoader.defaultCacheDirectory(),
    urlSession: URLSession? = nil,
    decoder: @escaping @MainActor (Data) async -> NSImage? = { NSImage(data: $0) }
  ) {
    let cache = URLCache(
      memoryCapacity: Self.memoryCapacityBytes,
      diskCapacity: max(0, diskCapacityBytes),
      directory: directory
    )
    if let urlSession {
      self.urlSession = urlSession
      self.urlCache = urlSession.configuration.urlCache ?? cache
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = cache
      configuration.requestCachePolicy = .returnCacheDataElseLoad
      // Artwork carries no credential and must never send one.
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.timeoutIntervalForRequest = 20
      configuration.timeoutIntervalForResource = 60
      configuration.waitsForConnectivity = false
      self.urlCache = cache
      self.urlSession = URLSession(configuration: configuration)
    }
    self.decoder = decoder
    decoded.countLimit = 512
  }

  package static func defaultCacheDirectory() -> URL? {
    FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent("com.macease.artwork", isDirectory: true)
  }

  /// The cover at `url`, or nil when it could not be loaded.
  ///
  /// Artwork is decoration: a failure returns nil so the row shows its
  /// placeholder. It is not reported as an app failure, because the user did
  /// not ask for a cover — they asked for a list, and they have it.
  package func image(for url: URL) async -> NSImage? {
    guard url.scheme?.lowercased() == "https", let host = url.host,
      NeteaseResourceHost.isApproved(host)
    else {
      return nil
    }
    if let cached = decoded.object(forKey: url as NSURL) {
      return cached
    }
    // The shared task yields bytes, not an image: `Task.value` is nonisolated,
    // so what crosses it has to be `Sendable` and `NSImage` is not. Decoding
    // happens below, on the main actor, and the cache check is repeated there
    // — every waiter resumes in turn, so the first decodes and the rest find
    // the result already cached.
    let entry = inFlight[url] ?? {
      let task = Task<Data?, Never> { [urlSession] in
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard
          let (data, response) = try? await urlSession.data(for: request),
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode)
        else { return nil }
        return data
      }
      let entry = InFlightTask(task)
      inFlight[url] = entry
      return entry
    }()

    let data = await entry.task.value
    defer {
      if inFlight[url] === entry { inFlight[url] = nil }
    }
    if let cached = decoded.object(forKey: url as NSURL) {
      return cached
    }
    guard let data, let image = await decoder(data) else { return nil }
    decoded.setObject(image, forKey: url as NSURL)
    return image
  }

  /// Returns only bytes already present in this loader's URLCache. Native
  /// notifications use it to prepare an optional temporary attachment without
  /// creating a second cover request or a second permanent image cache.
  package func cachedNotificationArtwork(
    for url: URL
  ) -> NativeNotificationArtwork? {
    guard url.scheme?.lowercased() == "https", let host = url.host,
      NeteaseResourceHost.isApproved(host)
    else {
      return nil
    }
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    guard let response = urlCache.cachedResponse(for: request),
      !response.data.isEmpty,
      response.data.count <= 10 * 1024 * 1024,
      let mimeType = response.response.mimeType?.lowercased(),
      let filenameExtension = Self.imageExtension(for: mimeType)
    else { return nil }
    return NativeNotificationArtwork(
      data: response.data,
      filenameExtension: filenameExtension
    )
  }

  /// What the settings page shows. `URLCache` reports what it has actually
  /// written, so this is the real number rather than a running total the app
  /// keeps and could get wrong.
  package var diskUsageBytes: Int { urlCache.currentDiskUsage }

  package func clear() {
    urlCache.removeAllCachedResponses()
    decoded.removeAllObjects()
  }

  /// Applies a new ceiling from the settings page. Shrinking it discards what
  /// is cached rather than leaving the old bytes in place: `URLCache` trims
  /// lazily, and a user who just asked for a smaller cache should see it get
  /// smaller.
  package func setDiskCapacity(_ bytes: Int) {
    let bytes = max(0, bytes)
    guard bytes != urlCache.diskCapacity else { return }
    if bytes < urlCache.currentDiskUsage {
      urlCache.removeAllCachedResponses()
    }
    urlCache.diskCapacity = bytes
  }

  private static func imageExtension(for mimeType: String) -> String? {
    switch mimeType {
    case "image/jpeg": "jpg"
    case "image/png": "png"
    case "image/gif": "gif"
    case "image/webp": "webp"
    case "image/heic": "heic"
    case "image/heif": "heif"
    case "image/avif": "avif"
    default: nil
    }
  }
}
