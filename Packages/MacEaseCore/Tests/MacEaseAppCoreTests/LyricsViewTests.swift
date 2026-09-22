import AppKit
import MacEaseSession
import SwiftUI
import Testing

@testable import MacEase
@testable import MacEaseAppCore
@testable import NeteaseKit

// Opt in on a Mac with a WindowServer. Hosts the production panel with fake
// transport/audio; never reads Keychain, contacts NetEase, or plays sound.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACEASE_TEST_LYRICS_UI"] == "1"))
@MainActor func lyricsPanelScrollsDuringPlaybackAndSeeking() async throws {
  _ = NSApplication.shared
  let suite = "MacEaseTests.LyricsView.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let transport = FakeTransport()
  let vault = FakeVault(stored: makeCredential())
  let arbiter = OperationArbiter()
  let session = LoginCoordinator(
    transport: transport, vault: vault, arbiter: arbiter, refreshDefaults: defaults)
  _ = await session.validateSession()
  let output = FakeAudioOutput()
  let playback = PlaybackController(
    transport: transport, vault: vault, arbiter: arbiter, output: output)
  playback.attach(session: session)
  let lyrics = LyricsCoordinator(transport: transport, vault: vault, arbiter: arbiter)
  let settings = AppSettings(defaults: defaults)
  let artwork = ArtworkLoader(diskCapacityBytes: 0, directory: nil)

  for verbatim in [false, true] {
    settings.usesVerbatimLyrics = verbatim
    let track = Track(id: verbatim ? 2 : 1, name: "Lyrics scroll regression")
    let lines = (0..<80).map { index in
      LyricLine(
        timeSeconds: Double(index), text: "Line \(index)",
        words: verbatim ? [
          LyricWord(startSeconds: Double(index), durationSeconds: 0.5, text: "Line "),
          LyricWord(startSeconds: Double(index) + 0.5, durationSeconds: 0.5, text: "\(index)"),
        ] : [])
    }
    await transport.setLyrics(.success(.lines(lines)))
    await transport.setSongURL(.success(makeResolvedAsset(songID: track.id)))
    playback.play(tracks: [track], startIndex: 0, context: .dailyRecommendations, session: session)
    await playback.settleForTesting()
    output.reportPosition(15)
    lyrics.setPanelVisible(true, track: track, session: session)
    await lyrics.settleForTesting()

    let host = NSHostingView(rootView: LyricsView(
      session: session, playback: playback, lyrics: lyrics, artwork: artwork, settings: settings))
    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 1100, height: 420),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(600))
    let scroll = try #require(lyricsScrollView(in: host))
    let initial = scroll.contentView.bounds.origin.y
    #expect(initial > 0, "Opening midway must reveal the current line (verbatim=\(verbatim))")

    output.reportPosition(40)
    try await Task.sleep(for: .milliseconds(600))
    let advanced = scroll.contentView.bounds.origin.y
    #expect(advanced > initial + 100, "Clock ticks must scroll while playing (verbatim=\(verbatim))")

    #expect(playback.seek(to: 65))
    try await Task.sleep(for: .milliseconds(600))
    let forward = scroll.contentView.bounds.origin.y
    #expect(forward > advanced + 100, "Forward seek must scroll without pause")
    #expect(playback.seek(to: 20))
    try await Task.sleep(for: .milliseconds(600))
    #expect(scroll.contentView.bounds.origin.y < forward - 100, "Backward seek must scroll without pause")
    #expect(playback.phase == .playing)
    print("Lyrics UI verbatim=\(verbatim): open=\(initial), tick=\(advanced), forward=\(forward), backward=\(scroll.contentView.bounds.origin.y)")
    let backward = scroll.contentView.bounds.origin.y
    lyrics.setOffset(-10, session: session)
    try await Task.sleep(for: .milliseconds(600))
    #expect(scroll.contentView.bounds.origin.y > backward + 100, "Offset changes must update the current line")
    #expect(playback.pause())
    #expect(playback.seek(to: 55))
    try await Task.sleep(for: .milliseconds(600))
    #expect(scroll.contentView.bounds.origin.y > advanced + 100, "Paused seek must update lyrics")
    #expect(playback.resume())
    output.reportPosition(10)
    try await Task.sleep(for: .milliseconds(600))
    #expect(scroll.contentView.bounds.origin.y < forward - 100, "Resuming must keep following progress")
    lyrics.setPanelVisible(false, track: track, session: session)
    playback.stop()
  }
}

@MainActor private func lyricsScrollView(in view: NSView) -> NSScrollView? {
  if let scroll = view as? NSScrollView { return scroll }
  return view.subviews.lazy.compactMap { lyricsScrollView(in: $0) }.first
}
