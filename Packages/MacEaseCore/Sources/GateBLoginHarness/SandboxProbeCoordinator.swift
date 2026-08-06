import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Observation
import Security
import UniformTypeIdentifiers

@MainActor
@Observable
final class SandboxProbeCoordinator {
  private static let bookmarkKey = "Phase0AudioBookmark"

  @ObservationIgnored private var outputListener: AudioObjectPropertyListenerBlock?
  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var scopedURL: URL?

  let sandboxStatus: String
  var audioStatus = "Not run"
  var bookmarkStatus = "Not run"
  var coreAudioStatus = "Not run"

  init() {
    let task = SecTaskCreateFromSelf(nil)!
    let value = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.security.app-sandbox" as CFString,
      nil
    )
    sandboxStatus = value as? Bool == true ? "Sandbox active" : "Sandbox inactive"
    if UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil {
      bookmarkStatus = "Stored audio bookmark available"
    }
  }

  func probeAVPlayer() async {
    releasePlayback()

    do {
      guard let bookmark = try resolveBookmark() else {
        audioStatus = "Select an audio file before AVPlayer"
        return
      }
      guard !bookmark.stale else {
        audioStatus = "Stored audio bookmark is stale"
        return
      }
      guard bookmark.url.startAccessingSecurityScopedResource() else {
        audioStatus = "Security-scoped audio access denied"
        return
      }
      scopedURL = bookmark.url

      let asset = AVURLAsset(url: bookmark.url)
      guard try await asset.load(.isPlayable) else {
        releasePlayback()
        audioStatus = "AVPlayer asset is not playable"
        return
      }

      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      self.player = player
      player.play()
      audioStatus = "AVPlayer play requested"
    } catch {
      releasePlayback()
      audioStatus = "AVPlayer probe failed: \(errorCode(error))"
    }
  }

  func stopAVPlayer() {
    releasePlayback()
    audioStatus = "AVPlayer stopped"
  }

  func probeCoreAudio() {
    guard outputListener == nil else {
      coreAudioStatus = "CoreAudio listener active"
      return
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &device
      ) == noErr,
      device != kAudioObjectUnknown
    else {
      coreAudioStatus = "CoreAudio default output unavailable"
      return
    }

    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.coreAudioStatus = "CoreAudio output change observed"
      }
    }
    guard
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        .main,
        listener
      ) == noErr
    else {
      coreAudioStatus = "CoreAudio listener failed"
      return
    }

    outputListener = listener
    coreAudioStatus = "CoreAudio default output read; listener active"
  }

  func stopCoreAudio() {
    guard let outputListener else {
      coreAudioStatus = "CoreAudio listener inactive"
      return
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        .main,
        outputListener
      ) == noErr
    else {
      coreAudioStatus = "CoreAudio listener stop failed"
      return
    }
    self.outputListener = nil
    coreAudioStatus = "CoreAudio listener stopped"
  }

  func probeBookmark() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    guard panel.runModal() == .OK, let url = panel.url else {
      bookmarkStatus = "File selection cancelled"
      return
    }

    do {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
      bookmarkStatus = "Security-scoped bookmark saved"
    } catch {
      bookmarkStatus = "Bookmark creation failed: \(errorCode(error))"
      return
    }

    do {
      guard let resolved = try resolveBookmark() else {
        bookmarkStatus = "Bookmark storage failed"
        return
      }
      guard !resolved.stale else {
        bookmarkStatus = "Security-scoped bookmark is stale"
        return
      }
      guard resolved.url.startAccessingSecurityScopedResource() else {
        bookmarkStatus = "Security-scoped access denied"
        return
      }
      defer { resolved.url.stopAccessingSecurityScopedResource() }

      _ = try resolved.url.resourceValues(forKeys: [.isRegularFileKey])
      bookmarkStatus = "Security-scoped bookmark saved and resolved"
    } catch {
      bookmarkStatus = "Bookmark resolution failed: \(errorCode(error))"
    }
  }

  private func resolveBookmark() throws -> (url: URL, stale: Bool)? {
    guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
      return nil
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: bookmark,
      options: .withSecurityScope,
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return (url, stale)
  }

  private func releasePlayback() {
    player?.pause()
    player = nil
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
  }

  private func errorCode(_ error: Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}
