import AppKit
import Foundation
import ImageIO
import MediaPlayer
import NeteaseKit
import Testing

@testable import MacEaseAppCore

private actor ArtworkRequestGate {
  private var arrivals = 0
  private var firstWaiter: CheckedContinuation<Void, Never>?
  private var firstIsOpen = false

  func waitForFirstRequest() async {
    arrivals += 1
    guard arrivals == 1, !firstIsOpen else { return }
    await withCheckedContinuation { firstWaiter = $0 }
  }

  func openFirstRequest() {
    firstIsOpen = true
    firstWaiter?.resume()
    firstWaiter = nil
  }

  func arrivalCount() -> Int { arrivals }
}

private final class InvalidArtworkURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var gate: ArtworkRequestGate?
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests = 0

  static func install(_ gate: ArtworkRequestGate) {
    self.gate = gate
    lock.withLock { requests = 0 }
  }

  static func remove() { gate = nil }

  static func requestCount() -> Int { lock.withLock { requests } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock { Self.requests += 1 }
    let gate = Self.gate
    let client = client
    let requestURL = request.url!
    Task {
      await gate?.waitForFirstRequest()
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "image/png"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      // Deliberately undecodable bytes exercise the loader's failed-decode path.
      client?.urlProtocol(self, didLoad: Data([0x01, 0x02, 0x03]))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

private actor ArtworkDecodeGate {
  let bitmap: CGImage
  private(set) var calls = 0
  private var waiter: CheckedContinuation<Void, Never>?

  init(bitmap: CGImage) { self.bitmap = bitmap }

  func decode() async -> CGImage? {
    calls += 1
    await withCheckedContinuation { waiter = $0 }
    return bitmap
  }

  func release() {
    waiter?.resume()
    waiter = nil
  }
}

@Test @MainActor func artworkCoalescesTransferAndDecodeAndClearDiscardsLateResults() async throws {
  let requestGate = ArtworkRequestGate()
  InvalidArtworkURLProtocol.install(requestGate)
  defer { InvalidArtworkURLProtocol.remove() }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [InvalidArtworkURLProtocol.self]
  let decodeGate = ArtworkDecodeGate(bitmap: try artworkTestBitmap())
  let loader = ArtworkLoader(
    diskCapacityBytes: 0, directory: nil,
    urlSession: URLSession(configuration: configuration),
    decoder: { _, _ in await decodeGate.decode() }
  )
  let url = URL(string: "https://p1.music.126.net/artwork-race.png")!
  let first = Task { await loader.image(for: url) == nil }
  while await requestGate.arrivalCount() < 1 { await Task.yield() }
  let second = Task { await loader.image(for: url) == nil }
  await requestGate.openFirstRequest()
  while await decodeGate.calls < 1 { await Task.yield() }
  for _ in 0..<20 { await Task.yield() }
  #expect(InvalidArtworkURLProtocol.requestCount() == 1)
  #expect(await decodeGate.calls == 1)
  loader.clear()
  await decodeGate.release()
  #expect(await first.value)
  #expect(await second.value)

  let replacement = Task { await loader.image(for: url) == nil }
  while await decodeGate.calls < 2 { await Task.yield() }
  let follower = Task { await loader.image(for: url) == nil }
  let cancelled = Task { await loader.image(for: url) == nil }
  for _ in 0..<20 { await Task.yield() }
  cancelled.cancel()
  #expect(InvalidArtworkURLProtocol.requestCount() == 2)
  await decodeGate.release()
  #expect(await replacement.value == false)
  #expect(await follower.value == false)
  #expect(await cancelled.value)
  #expect(await loader.image(for: url) != nil)
  #expect(await decodeGate.calls == 2)
  #expect(InvalidArtworkURLProtocol.requestCount() == 2)
}

@Test func artworkRequestsReplaceSizeAndPreserveOtherQueryItems() throws {
  let original = try #require(URL(string: "https://p1.music.126.net/cover.jpg?param=3000y3000&v=2"))
  let sized = NeteaseArtworkURL.sized(original, pixels: 128)
  let items = try #require(URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems)
  #expect(items == [URLQueryItem(name: "v", value: "2"), URLQueryItem(name: "param", value: "128y128")])
}

private func artworkTestBitmap() throws -> CGImage {
  let context = try #require(CGContext(
    data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ))
  return try #require(context.makeImage())
}

@Test func artworkDecodeCapsOriginalDimensions() async throws {
  let bitmap = try artworkTestBitmap()
  let bytes = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, bitmap, nil)
  #expect(CGImageDestinationFinalize(destination))
  let thumbnail = try #require(await ArtworkLoader.decode(bytes as Data, variant: .thumbnail))
  #expect(thumbnail.width == 128)
  #expect(thumbnail.height == 64)
  let display = try #require(await ArtworkLoader.decode(bytes as Data, variant: .display))
  #expect(display.width == 512)
  #expect(display.height == 256)
}

@Test @MainActor func systemArtworkCanBeRequestedOffMainThread() async throws {
  let bitmap = try artworkTestBitmap()
  // Use the production factory and the actual MediaPlayer callback from a
  // worker, as the system does when serializing Now Playing artwork.
  let dimensions = await Task.detached {
    let artwork = MPSystemMediaController.mediaArtwork(bitmap)
    let image = artwork.image(at: CGSize(width: 128, height: 64))
    return image?.size
  }.value
  #expect(dimensions != nil)
  #expect(dimensions!.width > 0)
}
