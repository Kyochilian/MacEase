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

/// An album row with its cover, shared by search, new releases and the artist
/// page.
struct AlbumRowLabel: View {
  let album: Album
  let loader: ArtworkLoader

  var body: some View {
    HStack(spacing: 8) {
      Artwork(url: album.artworkURL, size: 40, symbol: "opticaldisc", loader: loader)
      VStack(alignment: .leading, spacing: 3) {
        Text(album.name)
        Text(
          (album.artistDisplayName.map { $0 + " · " } ?? "")
            + "\(album.trackCount) tracks"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

/// An artist row with its photo, shared by search, similar artists and the
/// artist chart.
struct ArtistRowLabel: View {
  let artist: Artist
  let loader: ArtworkLoader

  var body: some View {
    HStack(spacing: 8) {
      Artwork(
        url: artist.artworkURL,
        size: 40,
        symbol: "music.microphone",
        loader: loader
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(artist.name)
        Text("\(artist.albumCount) albums · \(artist.songCount) songs")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// A playlist row with its cover, shared by discovery, browsing, the radar
/// family and search.
struct PlaylistRowLabel: View {
  let playlist: DiscoveredPlaylist
  let loader: ArtworkLoader

  var body: some View {
    HStack(spacing: 8) {
      Artwork(
        url: playlist.artworkURL,
        size: 40,
        symbol: "music.note.list",
        loader: loader
      )
      Text(playlist.name)
    }
  }
}

/// The heart is tri-state. "Not loaded yet" is shown as a distinct neutral
/// state and offers an explicit Like, rather than an empty heart whose toggle
/// would be guessing the starting value.
struct LikeButton: View {
  let track: Track
  let library: PlaylistLibraryCoordinator
  let session: LoginCoordinator
  let disabled: Bool

  var body: some View {
    let state = library.liked.state(of: track.id)
    Button {
      library.setLiked(state != .liked, for: track, session: session)
    } label: {
      Image(systemName: state == .liked ? "heart.fill" : "heart")
        .foregroundStyle(
          state == .liked ? AnyShapeStyle(.red) : AnyShapeStyle(colour(for: state))
        )
    }
    .buttonStyle(.borderless)
    .disabled(session.account == nil || disabled)
    .help(help(for: state))
    .accessibilityLabel(accessibilityLabel(for: state))
  }

  private func colour(for state: LikedState) -> HierarchicalShapeStyle {
    state == .notLiked ? .secondary : .tertiary
  }

  private func help(for state: LikedState) -> String {
    switch state {
    case .liked: "Unlike · 1 request"
    case .notLiked: "Like · 1 request"
    case .unknown: "Liked state unknown; this likes the track · 1 request"
    }
  }

  private func accessibilityLabel(for state: LikedState) -> String {
    switch state {
    case .liked: "Liked, unlike \(track.name)"
    case .notLiked: "Not liked, like \(track.name)"
    case .unknown: "Liked state not loaded, like \(track.name)"
    }
  }
}

/// Shared by every track list so all of them add through the same write path.
struct AddToPlaylistMenu: View {
  let track: Track
  let library: PlaylistLibraryCoordinator
  let session: LoginCoordinator
  let disabled: Bool

  var body: some View {
    Menu {
      ForEach(library.playlists.filter(\.owned), id: \.id) { target in
        Button(target.name) {
          library.addTrack(track, to: target, session: session)
        }
      }
    } label: {
      Image(systemName: "text.badge.plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(disabled || !library.playlists.contains(where: \.owned))
    .help("Add to one of your playlists · 1 request")
    .accessibilityLabel("Add \(track.name) to a playlist")
  }
}

/// The same local queue command is available from every ordinary track row.
/// Its captured account and revision make a menu left open across a sign-in
/// change fail closed instead of editing the replacement account's queue.
struct QueueNextButton: View {
  let track: Track
  let context: PlaybackContext
  let playback: PlaybackController
  let session: LoginCoordinator

  var body: some View {
    let snapshot = playback.queueSnapshot
    let accountID = snapshot?.accountID ?? session.account?.userID
    let revision = snapshot?.revision ?? playback.queueRevision
    let canQueue = accountID.map {
      playback.canQueueNext(
        context: context,
        accountID: $0,
        revision: revision,
        session: session
      )
    } ?? false
    Button {
      guard let accountID else { return }
      _ = playback.queueNext(
        track,
        context: context,
        accountID: accountID,
        revision: revision,
        session: session
      )
    } label: {
      Image(systemName: "text.line.first.and.arrowtriangle.forward")
    }
    .buttonStyle(.borderless)
    .disabled(!canQueue || snapshot?.current.id == track.id)
    .help("Play next · local queue edit, no request")
    .accessibilityLabel("Play \(track.name) next")
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
    HStack(spacing: 6) {
      QueueNextButton(
        track: track,
        context: context,
        playback: playback,
        session: session
      )
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
