import AppKit
import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI
import UniformTypeIdentifiers

/// Collected albums, followed artists and the cloud drive.
///
struct CollectionsView: View {
  typealias Section = CollectionsCoordinator.Section

  let session: LoginCoordinator
  let collections: CollectionsCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  let openAlbum: (Int64) -> Void
  let openArtist: (Int64) -> Void
  let downloads: DownloadCoordinator?
  @Binding var section: Section
  @State private var pendingCloudDeletion: CloudSong?
  @State private var cloudDetailIsPresented = false
  @State private var matchText = ""

  private var requestInFlight: Bool { collections.isLoading || !arbiter.canBegin(effect: .write) }
  private var loadDisabled: Bool {
    !session.isOnline || collections.writingSection == section || collections.isLoading(section)
  }

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
        if section == .cloud {
          Button("Upload…", systemImage: "icloud.and.arrow.up") {
            chooseCloudFile(importOnly: false)
          }
          .disabled(loadDisabled)
          Button("Import Existing File…") { chooseCloudFile(importOnly: true) }
            .disabled(loadDisabled)
        }
        if section == .cloud, let capacity = collections.cloudCapacity {
          Text(
            ByteFormat.short(capacity.usedBytes) + " of "
              + ByteFormat.short(capacity.totalBytes) + " used"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        Button("Load", systemImage: "arrow.clockwise") {
          load(reset: true)
        }
        .disabled(loadDisabled)
      }
      .padding(12)

      Divider()

      content

      Divider()

      HStack {
        if let progress = collections.uploadProgress {
          switch progress {
          case .preparing: Text("Preparing file…")
          case .transferring(let value): ProgressView(value: value).frame(width: 100)
          case .publishing: Text("Publishing…")
          }
          Button("Cancel Upload") { collections.cancelCloudUpload() }
        }
        if collections.isLoading {
          ProgressView().controlSize(.small)
        }
        Text(collections.status)
          .foregroundStyle(.secondary)
        Spacer()
        if hasMore {
          Button("Load More", systemImage: "plus") {
            load(reset: false)
          }
          .disabled(loadDisabled)
        }
      }
      .padding(12)
    }
    .task(id: "\(session.account?.userID ?? 0)-\(session.isOnline)-\(section)") {
      if session.isOnline { collections.loadIfNeeded(section, session: session) }
    }
    .confirmationDialog(
      "Delete this file from your cloud drive?",
      isPresented: Binding(
        get: { pendingCloudDeletion != nil }, set: { if !$0 { pendingCloudDeletion = nil } }
      )
    ) {
      Button("Delete", role: .destructive) {
        if let song = pendingCloudDeletion { collections.deleteCloudSong(song, session: session) }
        pendingCloudDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingCloudDeletion = nil }
    }
    .sheet(isPresented: $cloudDetailIsPresented) { cloudDetails }
    .onChange(of: collections.selectedCloudSong?.id) {
      cloudDetailIsPresented = collections.selectedCloudSong != nil
      matchText = collections.selectedCloudSong?.track.catalogSongID.map(String.init) ?? ""
    }
    .onChange(of: session.account?.userID) {
      cloudDetailIsPresented = false
      matchText = ""
      pendingCloudDeletion = nil
    }
  }

  @ViewBuilder private var cloudDetails: some View {
    if let song = collections.selectedCloudSong {
      Form {
        Text(song.track.name).font(.headline)
        LabeledContent("File", value: song.fileName)
        LabeledContent("Size", value: ByteFormat.short(song.fileSize))
        LabeledContent("Artist", value: song.track.artistDisplayName ?? "Unknown")
        LabeledContent(
          "Matched song", value: song.track.catalogSongID.map(String.init) ?? "Unmatched")
        TextField("Match to a song link or ID", text: $matchText)
        HStack {
          Button("Update Match") {
            if let id = matchingSongID {
              collections.matchCloudSong(song, to: id, session: session)
            }
          }.disabled(loadDisabled || matchingSongID == nil)
          Button("Remove Match") { collections.matchCloudSong(song, to: 0, session: session) }
            .disabled(loadDisabled)
          Button("Done") { cloudDetailIsPresented = false }
        }
        Text(collections.status).font(.caption).foregroundStyle(.secondary)
      }
      .padding().frame(width: 480)
    }
  }

  private func chooseCloudFile(importOnly: Bool) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        await collections.uploadCloudFile(at: url, importOnly: importOnly, session: session)
      }
    }
  }

  private var matchingSongID: Int64? {
    let text = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = Int64(text), id > 0 { return id }
    if let url = URL(string: text), let link = NeteaseMusicLink(url: url), case .song(let id) = link
    {
      return id
    }
    return nil
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
            Button(album.name) { openAlbum(album.id) }
              .buttonStyle(.plain)
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
          .help("Remove from your collected albums")
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
            Button(artist.name) { openArtist(artist.id) }
              .buttonStyle(.plain)
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
          .help("Unfollow")
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
          Button("Details") {
            if collections.selectedCloudSong?.id == song.id { cloudDetailIsPresented = true }
            collections.openCloudSong(song, session: session)
          }.disabled(loadDisabled)
          DownloadTrackButton(
            track: song.track, quality: playback.quality, downloads: downloads, session: session,
            disabled: requestInFlight)
          Button {
            pendingCloudDeletion = song
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .disabled(loadDisabled)
          .help("Delete from the cloud drive")
          .accessibilityLabel("Delete \(song.track.name)")
          PlayTrackButton(
            track: song.track,
            tracks: collections.cloudSongs.map(\.track),
            context: .cloudDrive,
            playback: playback,
            session: session
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
