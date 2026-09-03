import AppKit
import Foundation
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

@MainActor
private final class ArtworkDecodeGate {
  private(set) var calls = 0
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

  func decode(_ data: Data) async -> NSImage? {
    calls += 1
    let call = calls
    if call == 2 || call == 3 {
      await withCheckedContinuation { waiters[call] = $0 }
    }
    return nil
  }

  func release(_ call: Int) {
    waiters.removeValue(forKey: call)?.resume()
  }
}

@Test @MainActor func aFailedArtworkDecodeCannotClearAReplacementInFlightTask() async {
  let requestGate = ArtworkRequestGate()
  InvalidArtworkURLProtocol.install(requestGate)
  defer { InvalidArtworkURLProtocol.remove() }

  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [InvalidArtworkURLProtocol.self]
  configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
  let urlSession = URLSession(configuration: configuration)
  let decodeGate = ArtworkDecodeGate()
  let loader = ArtworkLoader(
    diskCapacityBytes: 0,
    directory: nil,
    urlSession: urlSession,
    decoder: { data in await decodeGate.decode(data) }
  )
  let url = URL(string: "https://p1.music.126.net/artwork-race.png")!

  let first = Task { @MainActor in _ = await loader.image(for: url) }
  while await requestGate.arrivalCount() < 1 { await Task.yield() }
  let second = Task { @MainActor in _ = await loader.image(for: url) }
  for _ in 0..<20 { await Task.yield() }
  #expect(InvalidArtworkURLProtocol.requestCount() == 1)
  await requestGate.openFirstRequest()
  while decodeGate.calls < 2 { await Task.yield() }

  let third = Task { @MainActor in _ = await loader.image(for: url) }
  while await requestGate.arrivalCount() < 2 || decodeGate.calls < 3 {
    await Task.yield()
  }

  decodeGate.release(2)
  await second.value
  let fourth = Task { @MainActor in _ = await loader.image(for: url) }
  for _ in 0..<20 { await Task.yield() }

  #expect(InvalidArtworkURLProtocol.requestCount() == 2)

  decodeGate.release(3)
  _ = await first.value
  _ = await third.value
  _ = await fourth.value
}
