import AppKit
import Foundation
import ImageIO
import NeteaseKit
import UniformTypeIdentifiers

/// The two sizes artwork is ever drawn at. Each is one address on the CDN and
/// one entry in each cache tier, so thirty rows and one header showing the
/// same album share a single request and a single decoded bitmap.
package enum ArtworkVariant: Sendable {
  /// Rows and headers, drawn at up to 64 points.
  case thumbnail
  /// The system Now Playing surface and notification attachments.
  case display

  package var pixels: Int {
    switch self {
    case .thumbnail: 128
    case .display: 512
    }
  }
}

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
/// not `Sendable`, so a background actor could only ever hand back bytes. The
/// transfer is off-thread inside `URLSession` and the decode is off-thread in
/// ImageIO; only the finished `CGImage`, which is `Sendable`, comes back here.
@MainActor
package final class ArtworkLoader {
  /// Cheap for artwork, which is a few tens of kilobytes per cover, and small
  /// enough that the decoded tier is never the reason memory grows.
  private static let memoryCapacityBytes = 32 * 1024 * 1024
  /// Decoded bitmaps: 128-pixel thumbnails are 64 KB each, so this holds a
  /// whole library's worth of rows while bounding the larger display tier.
  private static let decodedCostLimitBytes = 64 * 1024 * 1024

  private let urlSession: URLSession
  private let urlCache: URLCache
  private let decoder: @Sendable (Data, ArtworkVariant) async -> CGImage?
  private let decoded = NSCache<NSURL, NSImage>()
  private final class InFlightTask {
    let task: Task<CGImage?, Never>
    var waiters = 0

    init(_ task: Task<CGImage?, Never>) { self.task = task }
  }

  private var inFlight: [URL: InFlightTask] = [:]

  package init(
    diskCapacityBytes: Int,
    directory: URL? = ArtworkLoader.defaultCacheDirectory(),
    urlSession: URLSession? = nil,
    decoder: @escaping @Sendable (Data, ArtworkVariant) async -> CGImage? =
      ArtworkLoader.decode
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
    decoded.totalCostLimit = Self.decodedCostLimitBytes
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
  package func image(
    for url: URL,
    variant: ArtworkVariant = .thumbnail
  ) async -> NSImage? {
    guard !Task.isCancelled else { return nil }
    guard let url = Self.request(for: url, variant: variant) else { return nil }
    if let cached = decoded.object(forKey: url as NSURL) {
      return cached
    }
    // Share both transfer and decode. CGImage can cross Task.value safely;
    // NSImage is created and cached only after returning to the main actor.
    let entry = inFlight[url] ?? {
      let task = Task<CGImage?, Never> { [urlSession, decoder] in
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard
          let (data, response) = try? await urlSession.data(for: request),
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode)
        else { return nil }
        guard !Task.isCancelled else { return nil }
        return await decoder(data, variant)
      }
      let entry = InFlightTask(task)
      inFlight[url] = entry
      return entry
    }()

    entry.waiters += 1
    defer {
      entry.waiters -= 1
      if entry.waiters == 0, inFlight[url] === entry { inFlight[url] = nil }
    }
    let bitmap = await entry.task.value
    guard !Task.isCancelled, inFlight[url] === entry else { return nil }
    if let cached = decoded.object(forKey: url as NSURL) {
      return cached
    }
    guard let bitmap else { return nil }
    let image = NSImage(cgImage: bitmap, size: .zero)
    decoded.setObject(image, forKey: url as NSURL, cost: Self.bitmapCost(image))
    return image
  }

  /// Returns only bytes already present in this loader's URLCache. Native
  /// notifications use it to prepare an optional temporary attachment without
  /// creating a second cover request or a second permanent image cache. It
  /// looks for the display size, which is what Now Playing fetched for the
  /// same track moments earlier.
  package func cachedNotificationArtwork(
    for url: URL
  ) -> NativeNotificationArtwork? {
    guard let url = Self.request(for: url, variant: .display) else { return nil }
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
    for entry in inFlight.values { entry.task.cancel() }
    inFlight.removeAll()
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

  /// The address actually fetched: the server-supplied URL, approved, scaled
  /// to the variant. nil for anything MacEase will not load.
  package static func request(for url: URL, variant: ArtworkVariant) -> URL? {
    guard url.scheme?.lowercased() == "https", let host = url.host,
      NeteaseResourceHost.isApproved(host)
    else { return nil }
    return NeteaseArtworkURL.sized(url, pixels: variant.pixels)
  }

  /// Decodes off the main thread and never larger than the variant asked for.
  /// The CDN is expected to have scaled already; if it did not, the cap is
  /// what keeps a 3000-pixel original from becoming a 36-megabyte bitmap in
  /// the cache and a stall on the thread that draws the list.
  nonisolated package static func decode(
    _ data: Data,
    variant: ArtworkVariant
  ) async -> CGImage? {
    let pixels = variant.pixels
    let task = Task.detached(priority: .userInitiated) {
      Self.downsampled(data, maxPixels: pixels)
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  nonisolated static func downsampled(_ data: Data, maxPixels: Int) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
    else { return nil }
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }

  private static func bitmapCost(_ image: NSImage) -> Int {
    guard let representation = image.representations.first else { return 0 }
    return representation.pixelsWide * representation.pixelsHigh * 4
  }

  private static func imageExtension(for mimeType: String) -> String? {
    guard let type = UTType(mimeType: mimeType), type.conforms(to: .image)
    else { return nil }
    return type.preferredFilenameExtension
  }
}
