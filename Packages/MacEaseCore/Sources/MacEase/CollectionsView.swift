import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

/// Collected albums, followed artists and the cloud drive.
///
/// Each section loads and pages on an explicit action, and every button says
/// how many requests it costs, matching the rest of the app.
struct CollectionsView: View {
  private enum Section: Hashable {
    case albums
    case artists
    case cloud
  }

  let session: LoginCoordinator
  let collections: CollectionsCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  @State private var section: Section = .albums

  private var requestInFlight: Bool { collections.isLoading || arbiter.isBusy }
  private var loadDisabled: Bool { session.account == nil || requestInFlight }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Section", selection: $section) {
          Text("Albums").tag(Section.albums)
          Text("Artists").tag(Section.artists)
          Text("Cloud Drive").tag(Section.cloud)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Spacer()
        if section == .cloud, let capacity = collections.cloudCapacity {
          Text(
            ByteFormat.short(capacity.usedBytes) + " of "
              + ByteFormat.short(capacity.totalBytes) + " used"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        Button("Load · 1 request", systemImage: "arrow.clockwise") {
          load(reset: true)
        }
        .disabled(loadDisabled)
      }
      .padding(12)

      Divider()

      content

      Divider()

      HStack {
        if collections.isLoading {
          ProgressView().controlSize(.small)
        }
        Text(collections.status)
          .foregroundStyle(.secondary)
        Spacer()
        if hasMore {
          Button("Load More · 1 request", systemImage: "plus") {
            load(reset: false)
          }
          .disabled(loadDisabled)
        }
      }
      .padding(12)
    }
  }

  private var hasMore: Bool {
    switch section {
    case .albums: collections.albumsHaveMore
    case .artists: collections.artistsHaveMore
    case .cloud: collections.cloudHasMore
    }
  }

  private func load(reset: Bool) {
    switch section {
    case .albums: collections.loadAlbums(reset: reset, session: session)
    case .artists: collections.loadArtists(reset: reset, session: session)
    case .cloud: collections.loadCloud(reset: reset, session: session)
    }
  }

  @ViewBuilder private var content: some View {
    switch section {
    case .albums:
      list(collections.albums, empty: "Load your collected albums") { album in
        HStack(spacing: 8) {
          Artwork(url: album.artworkURL, size: 40, symbol: "opticaldisc", loader: artwork)
          VStack(alignment: .leading, spacing: 3) {
            Text(album.name)
            Text(
              (album.artistDisplayName.map { $0 + " · " } ?? "")
                + "\(album.trackCount) tracks"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            collections.setAlbumCollected(false, album: album, session: session)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .disabled(loadDisabled)
          .help("Remove from your collected albums · 1 request")
          .accessibilityLabel("Remove \(album.name)")
        }
      }
    case .artists:
      list(collections.artists, empty: "Load the artists you follow") { artist in
        HStack(spacing: 8) {
          Artwork(
            url: artist.artworkURL,
            size: 40,
            symbol: "music.microphone",
            loader: artwork
          )
          VStack(alignment: .leading, spacing: 3) {
            Text(artist.name)
            Text("\(artist.albumCount) albums · \(artist.songCount) songs")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            collections.setArtistFollowed(false, artist: artist, session: session)
          } label: {
            Image(systemName: "person.badge.minus")
          }
          .buttonStyle(.borderless)
          .disabled(loadDisabled)
          .help("Unfollow · 1 request")
          .accessibilityLabel("Unfollow \(artist.name)")
        }
      }
    case .cloud:
      list(collections.cloudSongs, empty: "Load your cloud drive") { song in
        HStack(spacing: 8) {
          TrackRowLabel(track: song.track, loader: artwork)
          Spacer()
          Text(ByteFormat.short(song.fileSize))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
          Button {
            collections.deleteCloudSong(song, session: session)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .disabled(loadDisabled)
          .help("Delete from the cloud drive · 1 request")
          .accessibilityLabel("Delete \(song.track.name)")
          PlayTrackButton(
            track: song.track,
            tracks: collections.cloudSongs.map(\.track),
            context: .cloudDrive,
            playback: playback,
            session: session,
            disabled: loadDisabled
          )
        }
      }
    }
  }

  @ViewBuilder private func list<Item: Identifiable, Row: View>(
    _ items: [Item],
    empty: String,
    @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    if items.isEmpty {
      Text(collections.isLoading ? collections.status : empty)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(items) { item in
        row(item).padding(.vertical, 3)
      }
    }
  }
}
