import AppKit
import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI
import UniformTypeIdentifiers

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
  @State private var filter = ""
  @State private var selectedTrackIDs: Set<Int64> = []
  @State private var isEditingMetadata = false
  @State private var descriptionText = ""
  @State private var tagsText = ""

  private var requestInFlight: Bool { library.isLoading || !arbiter.canBegin(effect: .write) }
  private var readInFlight: Bool { library.isLoading || !session.isOnline }
  private var visibleTracks: [Track] {
    let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? library.tracks
      : library.tracks.filter {
        $0.name.localizedCaseInsensitiveContains(query)
          || ($0.artistDisplayName?.localizedCaseInsensitiveContains(query) ?? false)
      }
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      createRow

      Divider()

      HSplitView {
        playlistList
          .overlay {
            if library.playlists.isEmpty && !library.isLoading {
              Text("Your playlists will appear here")
                .foregroundStyle(.secondary)
            }
          }
        detailPane
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
    .task(id: "\(session.account?.userID ?? 0)-\(session.isOnline)") {
      if session.isOnline { await library.loadAllPlaylists(session: session) }
    }
    .task(id: library.selectedPlaylist?.id) {
      if library.selectedPlaylist != nil { await library.loadRemainingTracks(session: session) }
    }
    .onChange(of: library.selectedPlaylist?.id) {

      renameText = library.selectedPlaylist?.name ?? ""
      isEditingMetadata = false
      descriptionText = ""
      tagsText = ""
      selectedTrackIDs = []
      filter = ""
    }
    .onChange(of: session.account?.userID) {
      isEditingMetadata = false
      descriptionText = ""
      tagsText = ""
      renameText = ""
      selectedTrackIDs = []
      playlistPendingDeletion = nil
      playlistPendingPublication = nil
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
    .sheet(isPresented: $isEditingMetadata) {
      Form {
        Text("Edit Playlist").font(.headline)
        TextField("Name", text: $renameText)
        Button("Save Name") { library.renameSelectedPlaylist(to: renameText, session: session) }
          .disabled(
            requestInFlight || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        TextEditor(text: $descriptionText).frame(height: 140)
          .accessibilityLabel("Playlist description")
        Button("Save Description") {
          library.updateSelectedMetadata(.description(descriptionText), session: session)
        }.disabled(requestInFlight || descriptionText.count > 1000)
        TextField("Tags separated by semicolons (up to 3)", text: $tagsText)
        Button("Save Tags") {
          let tags = tagsText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          library.updateSelectedMetadata(.tags(tags), session: session)
        }.disabled(requestInFlight)
        Button("Change Cover…") { chooseCover() }.disabled(requestInFlight)
        Text(library.status).font(.caption).foregroundStyle(.secondary)
        Button("Done") { isEditingMetadata = false }
      }.padding().frame(width: 480)
    }
    .confirmationDialog(
      playlistPendingDeletion.map { "Delete \($0.name)?" } ?? "Delete playlist?",
      isPresented: Binding(
        get: { playlistPendingDeletion != nil },
        set: { if !$0 { playlistPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
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
      Button("Make Public", role: .destructive) {
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
      Button("Liked Songs", systemImage: "heart.fill") {
        Task { await library.openLikedSongs(session: session) }
      }.disabled(!session.isOnline || readInFlight)
      Spacer()
      Button("Load Playlists", systemImage: "arrow.clockwise") {
        library.load(reset: true, session: session)
      }
      .disabled(session.account == nil || readInFlight)
      Button("Refresh Likes", systemImage: "heart") {
        library.loadLikedIDs(session: session)
      }
      .disabled(session.account == nil || readInFlight)
      .help("Marks loaded track rows that are in your liked songs")
      if library.canLoadMore {
        Button("Load All") { Task { await library.loadAllPlaylists(session: session) } }.disabled(
          readInFlight)
        Button("Load More", systemImage: "plus") {
          library.load(reset: false, session: session)
        }
        .disabled(readInFlight)
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
      Button("Create", systemImage: "plus.rectangle.on.folder") {
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
      selection: Binding(
        get: { library.selectedPlaylist?.id },
        set: { id in
          guard let playlist = library.playlists.first(where: { $0.id == id })
          else { return }
          library.loadTracks(for: playlist, session: session)
        }
      )
    ) {
      ForEach(library.playlists, id: \.id) { playlist in
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
          if playlist.canEdit {
            Button {
              playlistPendingDeletion = playlist
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(requestInFlight)
            .help("Delete playlist")
            .accessibilityLabel("Delete \(playlist.name)")
          } else if !playlist.owned {
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
            .help("Unsubscribe from this saved playlist")
            .accessibilityLabel("Unsubscribe from \(playlist.name)")
          }
        }
        .padding(.vertical, 3)
        .tag(playlist.id)
      }
      .onMove { offsets, destination in
        let ids = offsets.map { library.playlists[$0].id }
        let before = destination < library.playlists.count ? library.playlists[destination].id : nil
        library.movePlaylists(ids: ids, before: before, session: session)
      }
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
          HStack {
            TextField("Filter loaded songs", text: $filter)
            Text("Playback uses the complete playlist").font(.caption).foregroundStyle(.secondary)
            Menu("Selected Songs") {
              Button("Play Next") { queueSelected(next: true) }
              Button("Add to Queue") { queueSelected(next: false) }
              Button("Download") {
                downloads?.enqueueDownloads(
                  tracks: library.tracks.filter { selectedTrackIDs.contains($0.id) },
                  quality: playback.quality, session: session)
              }.disabled(downloads == nil || !session.isOnline)
              Menu("Add to Playlist") {
                ForEach(library.playlists.filter(\.canEdit), id: \.id) { target in
                  Button(target.name) {
                    library.editTracks(
                      .add, tracks: library.tracks.filter { selectedTrackIDs.contains($0.id) },
                      in: target, session: session)
                  }
                }
              }.disabled(requestInFlight)
            }.disabled(selectedTrackIDs.isEmpty)
            if playlist.canEdit {
              Button("Remove Selected") {
                library.editTracks(
                  .del, tracks: library.tracks.filter { selectedTrackIDs.contains($0.id) },
                  in: playlist, session: session)
              }.disabled(requestInFlight || selectedTrackIDs.isEmpty)
            }
          }.padding(8)
          List(selection: $selectedTrackIDs) {
            ForEach(visibleTracks) { track in trackRow(track).tag(track.id) }
              .onMove { indices, destination in
                let tracks = visibleTracks
                let ids = indices.map { tracks[$0].id }
                let before = destination < tracks.count ? tracks[destination].id : nil
                library.moveTracks(ids: ids, before: before, session: session)
              }
          }
        }
      } else {
        Text(
          "Choose a playlist to browse and play its songs."
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
      Artwork(url: playlist.artworkURL, size: 64, symbol: "music.note.list", loader: artwork)
      VStack(alignment: .leading, spacing: 3) {
        Text(playlist.name)
          .font(.headline)
        Text("\(playlist.trackCount) tracks")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let creator = playlist.creatorName { Text(creator).font(.caption) }
        if let tags = playlist.tags, !tags.isEmpty {
          Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
        if let description = playlist.description, !description.isEmpty {
          Text(description).font(.caption).lineLimit(3).textSelection(.enabled)
        }
      }
      Spacer()
      Button("Play All", systemImage: "play.fill") {
        library.playEntirePlaylist(playback: playback, session: session)
      }
      .disabled(!session.isOnline || (library.tracks.isEmpty && !library.canLoadMoreTracks))
      Button("Reload", systemImage: "arrow.clockwise") {
        library.loadTracks(for: playlist, session: session)
      }
      .disabled(!session.isOnline || arbiter.activeWriteIsInFlight)
      if library.isLoading {
        Button("Cancel") { library.cancelTrackLoading() }
          .disabled(arbiter.activeWriteIsInFlight)
      }
      Menu("Playlist") {
        if playlist.canEdit {
          Button("Edit Details…") {
            renameText = playlist.name
            descriptionText = playlist.description ?? ""
            tagsText = (playlist.tags ?? []).joined(separator: ";")
            isEditingMetadata = true
          }.disabled(requestInFlight)
          if playlist.isPrivate == true {
            Button("Make Public") { playlistPendingPublication = playlist }.disabled(
              requestInFlight)
          }
        } else if !playlist.owned {
          Button(playlist.isSubscribed == true ? "Unsave Playlist" : "Save Playlist") {
            library.setSubscribed(
              playlist.isSubscribed != true, playlistID: playlist.id, playlistName: playlist.name,
              session: session)
          }.disabled(!library.canWrite(session: session))
        }
        if library.canLoadMoreTracks {
          Button("Load More Songs") { library.loadMoreTracks(session: session) }.disabled(
            requestInFlight)
        }
        Button("Copy Link") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            NeteaseMusicLink.playlist(playlist.id).url.absoluteString, forType: .string)
        }
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
        .help("Remove from this playlist")
        .accessibilityLabel("Remove \(track.name)")
      }
      QueueNextButton(track: track, context: playbackContext, playback: playback, session: session)
      Button {
        library.playEntirePlaylist(startingAt: track.id, playback: playback, session: session)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Play \(track.name) in the complete playlist")
      .disabled(!session.isOnline)
    }
    .padding(.vertical, 3)
  }

  private func chooseCover() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.begin { result in
      guard result == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        await library.updateSelectedCover(from: url, session: session)
      }
    }
  }

  private func queueSelected(next: Bool) {
    guard let account = session.account else { return }
    _ = playback.enqueue(
      library.tracks.filter { selectedTrackIDs.contains($0.id) }, next: next,
      context: playbackContext, accountID: account.userID, revision: playback.queueRevision,
      session: session
    )
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
