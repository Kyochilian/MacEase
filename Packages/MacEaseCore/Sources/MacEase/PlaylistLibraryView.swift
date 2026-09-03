import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI


struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  let downloads: DownloadCoordinator?
  @State private var newPlaylistName = ""
  @State private var newPlaylistIsPrivate = false
  @State private var submittedPlaylistName: String?
  @State private var renameText = ""
  @State private var playlistPendingDeletion: UserPlaylist?
  @State private var playlistPendingPublication: UserPlaylist?

  private var requestInFlight: Bool { library.isLoading || arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      createRow

      Divider()

      if library.playlists.isEmpty && !library.isLoading {
        Text(library.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          playlistList
          detailPane
        }
      }

      Divider()

      HStack {
        if library.isLoading {
          ProgressView()
            .controlSize(.small)
        }
        Text(library.status)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(12)
    }
    .onChange(of: library.selectedPlaylist?.id) {
      renameText = library.selectedPlaylist?.name ?? ""
    }
    .onChange(of: library.lastCreateReceipt?.id) {
      guard let receipt = library.lastCreateReceipt, receipt.succeeded,
        let submitted = submittedPlaylistName
      else { return }
      // Only clear what this action submitted: a late completion must not
      // wipe a name the user has since typed.
      if newPlaylistName == submitted {
        newPlaylistName = ""
      }
      submittedPlaylistName = nil
    }
    .confirmationDialog(
      playlistPendingDeletion.map { "Delete \($0.name)?" } ?? "Delete playlist?",
      isPresented: Binding(
        get: { playlistPendingDeletion != nil },
        set: { if !$0 { playlistPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete · 1 request", role: .destructive) {
        if let playlist = playlistPendingDeletion {
          library.deletePlaylist(playlist, session: session)
        }
        playlistPendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { playlistPendingDeletion = nil }
    } message: {
      Text("This permanently deletes the playlist from your NetEase account.")
    }
    .confirmationDialog(
      playlistPendingPublication.map { "Make \($0.name) public?" }
        ?? "Make playlist public?",
      isPresented: Binding(
        get: { playlistPendingPublication != nil },
        set: { if !$0 { playlistPendingPublication = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Make Public · 1 request", role: .destructive) {
        if let playlist = playlistPendingPublication {
          library.publishPlaylist(playlist, session: session)
        }
        playlistPendingPublication = nil
      }
      Button("Cancel", role: .cancel) { playlistPendingPublication = nil }
    } message: {
      Text(
        "This permanently makes the playlist public. MacEase cannot make it private again."
      )
    }
  }

  @ViewBuilder private var toolbar: some View {
    HStack {
      Text("Your Playlists")
        .font(.headline)
      Spacer()
      Button("Load Playlists · 1 request", systemImage: "arrow.clockwise") {
        library.load(reset: true, session: session)
      }
      .disabled(session.account == nil || requestInFlight)
      Button("Load Liked IDs · 1 request", systemImage: "heart") {
        library.loadLikedIDs(session: session)
      }
      .disabled(session.account == nil || requestInFlight)
      .help("Marks loaded track rows that are in your liked songs")
      if library.canLoadMore {
        Button("Load More · 1 request", systemImage: "plus") {
          library.load(reset: false, session: session)
        }
        .disabled(requestInFlight)
      } else if library.playlistsNeedReload {
        // The page cursor no longer names the same server position, so
        // continuing from it could skip or repeat rows.
        Label("Reload to page further", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("A write changed your playlists; Load Playlists starts over")
      }
    }
    .padding(12)
  }

  @ViewBuilder private var createRow: some View {
    HStack {
      TextField("New playlist name", text: $newPlaylistName)
        .frame(maxWidth: 240)
      // Privacy is set when the playlist is created. That is the only
      // direction NetEase is known to accept, so it is the only one offered.
      Toggle("Private", isOn: $newPlaylistIsPrivate)
        .toggleStyle(.checkbox)
        .help("Creates the playlist private; only you can see it")
      Button("Create · 1 request", systemImage: "plus.rectangle.on.folder") {
        submittedPlaylistName = newPlaylistName
        library.createPlaylist(
          named: newPlaylistName,
          isPrivate: newPlaylistIsPrivate,
          session: session
        )
      }
      .disabled(
        session.account == nil || requestInFlight
          || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  @ViewBuilder private var playlistList: some View {
    List(
      library.playlists,
      id: \.id,
      selection: Binding(
        get: { library.selectedPlaylist?.id },
        set: { id in
          guard let playlist = library.playlists.first(where: { $0.id == id })
          else { return }
          library.loadTracks(for: playlist, session: session)
        }
      )
    ) { playlist in
      // Selection opens the playlist, so the row is not itself a button and
      // the trailing control is not nested inside one.
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(playlist.name)
          Text(
            "\(playlist.trackCount) tracks · "
              + (playlist.owned ? "Created" : "Saved")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        if playlist.owned {
          Button {
            playlistPendingDeletion = playlist
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .disabled(requestInFlight)
          .help("Delete playlist · 1 request")
          .accessibilityLabel("Delete \(playlist.name)")
        } else {
          Button {
            library.setSubscribed(
              false,
              playlistID: playlist.id,
              playlistName: playlist.name,
              session: session
            )
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .disabled(requestInFlight)
          .help("Unsubscribe from this saved playlist · 1 request")
          .accessibilityLabel("Unsubscribe from \(playlist.name)")
        }
      }
      .padding(.vertical, 3)
      .tag(playlist.id)
    }
    .frame(minWidth: 340)
  }

  @ViewBuilder private var detailPane: some View {
    VStack(spacing: 0) {
      if let playlist = library.selectedPlaylist {
        detailHeader(playlist)

        Divider()

        if library.tracks.isEmpty {
          Text(library.status)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(library.tracks, id: \.id) { track in
            trackRow(track)
          }
        }
      } else {
        Text(
          "Choose a playlist. The first batch uses one playlist-detail request "
            + "and, for a nonempty playlist, one song-detail request."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 340)
  }

  @ViewBuilder private func detailHeader(_ playlist: UserPlaylist) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(playlist.name)
          .font(.headline)
        Text("\(playlist.trackCount) tracks")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if playlist.owned {
        TextField("Rename", text: $renameText)
          .frame(maxWidth: 160)
        Button("Rename · 1 request") {
          library.renameSelectedPlaylist(to: renameText, session: session)
        }
        .disabled(
          requestInFlight
            || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .help("Changes only the name; description and tags are untouched")
        if playlist.isPrivate == true {
          Button("Make Public · 1 request") {
            playlistPendingPublication = playlist
          }
          .disabled(requestInFlight)
          .help("Permanently publishes this private playlist")
        }
      }
      if library.canLoadMoreTracks {
        Button("Load More Tracks · 1 request", systemImage: "plus") {
          library.loadMoreTracks(session: session)
        }
        .disabled(requestInFlight)
      } else if library.tracksNeedReload {
        Label("Reload to page further", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("A track was added; open the playlist again to page further")
      }
    }
    .padding(12)
  }

  @ViewBuilder private func trackRow(_ track: Track) -> some View {
    HStack {
      TrackRowLabel(track: track, loader: artwork)
      Spacer()
      LikeButton(
        track: track,
        library: library,
        session: session,
        disabled: requestInFlight
      )
      AddToPlaylistMenu(
        track: track,
        library: library,
        session: session,
        disabled: requestInFlight
      )
      DownloadTrackButton(
        track: track,
        quality: playback.quality,
        downloads: downloads,
        session: session,
        disabled: requestInFlight
      )
      if library.selectedPlaylist?.owned == true {
        Button {
          // Named by id: a list that changed cannot make this land on a
          // different row.
          library.removeSelectedPlaylistTrack(id: track.id, session: session)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(requestInFlight)
        .help("Remove from this playlist · 1 request")
        .accessibilityLabel("Remove \(track.name)")
      }
      PlayTrackButton(
        track: track,
        tracks: library.tracks,
        context: playbackContext,
        playback: playback,
        session: session
      )
      .help("Starts the queue from this track over the loaded list")
    }
    .padding(.vertical, 3)
  }

  /// The open playlist is what a restored queue names, so a relaunch can say
  /// what the user was listening to rather than just how many tracks it held.
  private var playbackContext: PlaybackContext {
    guard let playlist = library.selectedPlaylist else {
      return .dailyRecommendations
    }
    return .playlist(id: playlist.id, name: playlist.name)
  }
}

