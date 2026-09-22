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
      let loaded = await loader.image(for: url)
      guard !Task.isCancelled else { return }
      image = loaded
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
      if let notice = track.playbackNotice {
        Text(notice).font(.caption2).foregroundStyle(.secondary)
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
    .contextMenu {
      if let id = track.catalogIdentity {
        MusicLinkActions(link: .song(id))
      }
      if let album = track.album, let id = album.id {
        MusicLinkActions(link: .album(id), title: album.name)
      }
      ForEach(track.artists, id: \.self) { artist in
        if let id = artist.id { MusicLinkActions(link: .artist(id), title: artist.name) }
      }
    }
  }
}

private struct MusicLinkActions: View {
  @Environment(\.openURL) private var openURL
  let link: NeteaseMusicLink
  var title = "Details"
  var body: some View {
    Button("Open \(title)") { openURL(link.url) }
    Button("Copy \(title == "Details" ? "Song Link" : title + " Link")") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
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
    .contextMenu { MusicLinkActions(link: .album(album.id), title: album.name) }
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
    .contextMenu { MusicLinkActions(link: .artist(artist.id), title: artist.name) }
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
    let state = library.likedState(for: track)
    Button {
      library.setLiked(state != .liked, for: track, session: session)
    } label: {
      Image(systemName: state == .liked ? "heart.fill" : "heart")
        .foregroundStyle(
          state == .liked ? AnyShapeStyle(.red) : AnyShapeStyle(colour(for: state))
        )
    }
    .buttonStyle(.borderless)
    .disabled(!library.canLike(track, session: session) || disabled)
    .help(track.catalogIdentity == nil ? "Match this cloud file before liking it" : help(for: state))
    .accessibilityLabel(accessibilityLabel(for: state))
  }

  private func colour(for state: LikedState) -> HierarchicalShapeStyle {
    state == .notLiked ? .secondary : .tertiary
  }

  private func help(for state: LikedState) -> String {
    switch state {
    case .liked: "Unlike"
    case .notLiked: "Like"
    case .unknown: "Liked state unknown; this likes the track"
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
      ForEach(library.playlists.filter(\.canEdit), id: \.id) { target in
        Button(target.name) {
          library.addTrack(track, to: target, session: session)
        }
      }
    } label: {
      Image(systemName: "text.badge.plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(
      disabled || track.catalogIdentity == nil || !library.canWrite(session: session)
        || !library.playlists.contains(where: \.canEdit)
    )
    .help(track.catalogIdentity == nil
      ? "Match this cloud file before adding it to a playlist" : "Add to one of your playlists")
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
    let canQueue =
      accountID.map {
        playback.canQueueNext(
          context: context,
          accountID: $0,
          revision: revision,
          session: session
        )
      } ?? false
    Menu {
      Button("Play Next") {
        guard let accountID else { return }
        _ = playback.queueNext(
          track, context: context, accountID: accountID, revision: revision, session: session)
      }
      Button("Add to End of Queue") {
        guard let accountID else { return }
        _ = playback.enqueue(
          [track], next: false, context: context, accountID: accountID, revision: revision,
          session: session)
      }
    } label: {
      Image(systemName: "text.line.first.and.arrowtriangle.forward")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(!canQueue || snapshot?.current.id == track.id)
    .help("Play next")
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

struct TrackCollectionMenu: View {
  let tracks: [Track]
  let context: PlaybackContext
  let playback: PlaybackController
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let downloads: DownloadCoordinator?

  var body: some View {
    let accountID = session.account?.userID
    let revision = playback.queueRevision
    Menu("All Shown Songs (\(tracks.count))") {
      Button("Play") {
        guard session.account?.userID == accountID else { return }
        _ = playback.play(tracks: tracks, startIndex: 0, context: context, session: session)
      }
      Button("Play Next") {
        guard let accountID else { return }
        _ = playback.enqueue(
          tracks, next: true, context: context, accountID: accountID, revision: revision,
          session: session)
      }
      Button("Add to Queue") {
        guard let accountID else { return }
        _ = playback.enqueue(
          tracks, next: false, context: context, accountID: accountID, revision: revision,
          session: session)
      }
      Button("Download") {
        guard session.account?.userID == accountID else { return }
        downloads?.enqueueDownloads(tracks: tracks, quality: playback.quality, session: session)
      }.disabled(downloads == nil || !session.isOnline)
      Menu("Add to Playlist") {
        ForEach(library.playlists.filter(\.canEdit), id: \.id) { playlist in
          Button(playlist.name) {
            guard session.account?.userID == accountID else { return }
            library.editTracks(.add, tracks: tracks, in: playlist, session: session)
          }
        }
      }.disabled(!library.canWrite(session: session) || tracks.contains { $0.catalogIdentity == nil })
    }.disabled(tracks.isEmpty || accountID == nil)
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
        && $0.requestedQuality == quality && $0.isVerifiedComplete
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
          disabled || !session.isOnline
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
