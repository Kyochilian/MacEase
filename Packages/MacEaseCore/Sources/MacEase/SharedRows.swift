import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

/// Row pieces shared by the library, search, discover, records and collection
/// lists. They were private to the app file, so every new list either used a
/// hand-copied version or could not use them at all.

/// Cover art for one item.
///
/// It asks for the image only when it is about to be drawn, so a list that is
/// scrolled past costs nothing, and it falls back to a symbol rather than a
/// blank space: a missing cover is a normal state, not a failure to report.
struct Artwork: View {
  let url: URL?
  var size: CGFloat = 36
  var symbol = "music.note"
  let loader: ArtworkLoader

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.medium)
          .scaledToFill()
      } else {
        ZStack {
          Rectangle().fill(.quaternary)
          Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .font(.system(size: size * 0.4))
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .task(id: url) {
      image = nil
      guard let url else { return }
      image = await loader.image(for: url)
    }
    .accessibilityHidden(true)
  }
}

struct TrackLabel: View {
  let track: Track

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(track.name)
      if let artists = track.artistDisplayName {
        Text(albumSuffixed(artists))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The album is appended to the artist line rather than given a row of its
  /// own: it is the same piece of provenance, and a third line per row would
  /// half again the height of every list in the app.
  private func albumSuffixed(_ artists: String) -> String {
    guard let album = track.album?.name, !album.isEmpty else { return artists }
    return artists + " · " + album
  }
}

/// A track row with its cover, used by every list that shows tracks.
struct TrackRowLabel: View {
  let track: Track
  let loader: ArtworkLoader

  var body: some View {
    HStack(spacing: 8) {
      Artwork(url: track.artworkURL, loader: loader)
      TrackLabel(track: track)
      if let seconds = track.durationSeconds {
        Text(TimeFormat.short(seconds))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
  }
}

/// Resolves the row's position at action time from the track id, so a list
/// that changed between render and click cannot start the wrong track.
struct PlayTrackButton: View {
  let track: Track
  let tracks: [Track]
  let context: PlaybackContext
  let playback: PlaybackController
  let session: LoginCoordinator

  var body: some View {
    Button("Play", systemImage: "play.fill") {
      guard let index = tracks.firstIndex(where: { $0.id == track.id }) else {
        return
      }
      playback.play(
        tracks: tracks,
        startIndex: index,
        context: context,
        session: session
      )
    }
    .buttonStyle(.borderless)
    .disabled(session.account == nil)
    .accessibilityLabel("Play \(track.name)")
  }
}

/// The single foreground-download control shared by track rows and Now
/// Playing. It never starts automatically, and a running transfer exposes its
/// progress and cancel action wherever the same track is shown.
struct DownloadTrackButton: View {
  let track: Track
  let quality: PlaybackQuality
  let downloads: DownloadCoordinator?
  let session: LoginCoordinator
  let disabled: Bool

  private var isThisTrackActive: Bool {
    guard let downloads else { return false }
    switch downloads.activity {
    case .resolving(let songID), .transferring(let songID):
      return songID == track.id
    case .idle:
      return false
    }
  }

  private var isDownloaded: Bool {
    guard let accountID = session.account?.userID else { return false }
    return downloads?.downloads.contains {
      $0.accountID == accountID && $0.track.id == track.id
        && $0.requestedQuality == quality
    } == true
  }

  var body: some View {
    if let downloads {
      if isThisTrackActive {
        if let progress = downloads.progress {
          ProgressView(value: progress)
            .frame(width: 44)
            .accessibilityLabel("Downloading \(track.name)")
            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
        } else {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Resolving download for \(track.name)")
        }
        Button {
          downloads.cancelDownload()
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Cancel this download")
        .accessibilityLabel("Cancel download of \(track.name)")
      } else if isDownloaded {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
          .help("Downloaded at \(quality.rawValue) quality")
          .accessibilityLabel("\(track.name) is downloaded")
      } else {
        Button {
          downloads.startDownload(
            track: track,
            quality: quality,
            session: session
          )
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .buttonStyle(.borderless)
        .disabled(
          disabled || session.account == nil || downloads.isDownloading
            || downloads.isMaintaining || downloads.isLoading
            || !downloads.canCreateDownloads
        )
        .help(
          downloads.downloadCreationUnavailableReason
            ?? "Download this song for offline playback"
        )
        .accessibilityLabel("Download \(track.name)")
      }
    }
  }
}

/// One place that renders a byte count, so the cloud drive and the caches do
/// not each spell megabytes differently.
enum ByteFormat {
  static func short(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: max(0, bytes))
  }
}

enum TimeFormat {
  static func short(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
