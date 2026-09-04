import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

/// Searching the whole catalogue, either as four concurrent bounded groups or
/// in one pageable category.
///
/// Suggestions appear after a short pause in typing and only ever fill the
/// field; the search itself always waits for the user to submit it. Paging
/// asks for the rows after the ones already held, so a result set that shifts
/// between requests cannot make it skip.
struct SearchView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var catalog: CatalogCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  let openPlaylist: (DiscoveredPlaylist) -> Void
  let openAlbum: (Int64) -> Void
  let openArtist: (Int64) -> Void

  private var requestInFlight: Bool { catalog.isSearching || arbiter.isBusy }
  private var trimmedQuery: String {
    catalog.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var searchDisabled: Bool {
    session.account == nil || requestInFlight || trimmedQuery.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Kind", selection: $catalog.scope) {
          Text("All").tag(CatalogSearchScope.all)
          Text("Songs").tag(CatalogSearchScope.songs)
          Text("Artists").tag(CatalogSearchScope.artists)
          Text("Albums").tag(CatalogSearchScope.albums)
          Text("Playlists").tag(CatalogSearchScope.playlists)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        // Scope edits supersede a search already in flight, so the picker must
        // remain available while that read is running.
        .disabled(session.account == nil || arbiter.isBusy)
        TextField(placeholder, text: $catalog.query)
          .onSubmit {
            if !searchDisabled { catalog.runSearch(session: session) }
          }
        Button(searchButtonTitle, systemImage: "magnifyingglass") {
          catalog.runSearch(session: session)
        }
        .disabled(searchDisabled)
        .help(
          catalog.scope == .all
            ? "Searches songs, artists, albums, and playlists with 4 concurrent requests"
            : "Searches the selected category with 1 request"
        )
        Button("Suggested Search · 1 request", systemImage: "sparkle") {
          catalog.loadDefaultKeyword(session: session)
        }
        .disabled(session.account == nil || requestInFlight)
        .help("Shows what NetEase suggests searching for; it never searches")
      }
      .padding(12)
      // Typing is not a search. This only refreshes the suggestion list, after
      // a pause, and clearing the field clears it without a request.
      .onChange(of: catalog.query) {
        catalog.updateSuggestions(session: session)
      }
      .onDisappear { catalog.cancelSuggestions() }

      if !catalog.suggestions.isEmpty {
        suggestions
      }

      Divider()

      results

      Divider()

      HStack {
        if catalog.isSearching { ProgressView().controlSize(.small) }
        Text(catalog.status)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        if catalog.resultsHaveMore {
          Button("Load More · 1 request", systemImage: "plus") {
            catalog.loadMoreResults(session: session)
          }
          .disabled(session.account == nil || requestInFlight)
        }
      }
      .padding(12)
    }
  }

  private var placeholder: String {
    catalog.defaultKeyword.map { "Search · try \($0)" } ?? "Search"
  }

  private var searchButtonTitle: String {
    catalog.scope == .all ? "Search · 4 requests" : "Search · 1 request"
  }

  @ViewBuilder private var suggestions: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(catalog.suggestions) { suggestion in
          Button {
            // Filling the field is all this does. The user still submits.
            catalog.query = suggestion.keyword
          } label: {
            VStack(alignment: .leading, spacing: 1) {
              Text(suggestion.keyword)
              if let detail = suggestion.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.bordered)
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
    }
    .scrollIndicators(.hidden)
  }

  @ViewBuilder private var results: some View {
    if catalog.scope == .all {
      combinedResults
    } else {
      scopedResults
    }
  }

  @ViewBuilder private var scopedResults: some View {
    switch catalog.results {
    case .songs(let songs):
      list(songs, empty: "Search for a song") { track in
        songRow(track, tracks: songs)
      }
    case .albums(let albums):
      list(albums, empty: "Search for an album") { album in
        albumRow(album)
      }
    case .artists(let artists):
      list(artists, empty: "Search for an artist") { artist in
        artistRow(artist)
      }
    case .playlists(let playlists):
      list(playlists, empty: "Search for a playlist") { playlist in
        playlistRow(playlist)
      }
    }
  }

  @ViewBuilder private var combinedResults: some View {
    let combined = catalog.combinedResults
    if combined.isEmpty {
      VStack(spacing: 8) {
        Text(catalog.isSearching ? catalog.status : "Search across all categories")
          .foregroundStyle(.secondary)
        if combined.isIncomplete {
          Label("Results are incomplete", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List {
        if combined.isIncomplete {
          Section {
            Label("Results are incomplete", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        if !combined.songs.isEmpty {
          Section("Songs") {
            ForEach(combined.songs) { songRow($0, tracks: combined.songs) }
          }
        }
        if !combined.artists.isEmpty {
          Section("Artists") {
            ForEach(combined.artists) { artistRow($0) }
          }
        }
        if !combined.albums.isEmpty {
          Section("Albums") {
            ForEach(combined.albums) { albumRow($0) }
          }
        }
        if !combined.playlists.isEmpty {
          Section("Playlists") {
            ForEach(combined.playlists) { playlistRow($0) }
          }
        }
      }
    }
  }

  private func songRow(_ track: Track, tracks: [Track]) -> some View {
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
      PlayTrackButton(
        track: track,
        tracks: tracks,
        context: .searchResults(keywords: catalog.resultsKeywords ?? ""),
        playback: playback,
        session: session
      )
    }
  }

  private func albumRow(_ album: Album) -> some View {
    HStack {
      AlbumRowLabel(album: album, loader: artwork)
      Spacer()
      Button("Open · 2 requests", systemImage: "opticaldisc") {
        openAlbum(album.id)
      }
      .buttonStyle(.borderless)
      .disabled(session.account == nil || arbiter.isBusy)
    }
  }

  private func artistRow(_ artist: Artist) -> some View {
    HStack {
      ArtistRowLabel(artist: artist, loader: artwork)
      Spacer()
      Button("Open · 2 requests", systemImage: "music.microphone") {
        openArtist(artist.id)
      }
      .buttonStyle(.borderless)
      .disabled(session.account == nil || arbiter.isBusy)
    }
  }

  private func playlistRow(_ playlist: DiscoveredPlaylist) -> some View {
    HStack {
      PlaylistRowLabel(playlist: playlist, loader: artwork)
      Spacer()
      Button("Open · up to 2 requests", systemImage: "music.note.list") {
        openPlaylist(playlist)
      }
      .buttonStyle(.borderless)
      .disabled(session.account == nil || arbiter.isBusy)
      Button {
        library.setSubscribed(
          true,
          playlistID: playlist.id,
          playlistName: playlist.name,
          session: session
        )
      } label: {
        Image(systemName: "plus.circle")
      }
      .buttonStyle(.borderless)
      .disabled(session.account == nil || arbiter.isBusy)
      .help("Subscribe to this playlist · 1 request")
    }
  }

  @ViewBuilder private func list<Item: Identifiable, Row: View>(
    _ items: [Item],
    empty: String,
    @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    if items.isEmpty {
      Text(catalog.isSearching ? catalog.status : empty)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(items) { row($0).padding(.vertical, 3) }
    }
  }
}

/// The album and artist pages, plus the two lists you browse into them from:
/// new releases and the artist chart.
///
/// Collecting an album and following an artist go through
/// `CollectionsCoordinator`, the same write path the Collections tab uses, so
/// there is one place that owns those two mutations.
struct CatalogView: View {
  enum Pane: Hashable {
    case album
    case artist
    case newReleases
    case topArtists
  }

  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var catalog: CatalogCoordinator
  let collections: CollectionsCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  /// Wired by the composition root so the Discover tab's Similar Artists
  /// section stays the one place that list lives.
  let showSimilarArtists: (Artist) -> Void
  @Binding var pane: Pane

  private var requestInFlight: Bool {
    catalog.isLoadingDetail || collections.isLoading || arbiter.isBusy
  }
  private var loadDisabled: Bool { session.account == nil || requestInFlight }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Pane", selection: $pane) {
          Text("Album").tag(Pane.album)
          Text("Artist").tag(Pane.artist)
          Text("New Releases").tag(Pane.newReleases)
          Text("Top Artists").tag(Pane.topArtists)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Spacer()
      }
      .padding(12)

      Divider()

      switch pane {
      case .album: albumPane
      case .artist: artistPane
      case .newReleases: newReleasesPane
      case .topArtists: topArtistsPane
      }

      Divider()

      HStack {
        if catalog.isLoadingDetail { ProgressView().controlSize(.small) }
        Text(catalog.detailStatus)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
      }
      .padding(12)
    }
  }

  // MARK: - Album

  @ViewBuilder private var albumPane: some View {
    if let detail = catalog.album {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Artwork(
            url: detail.album.artworkURL,
            size: 56,
            symbol: "opticaldisc",
            loader: artwork
          )
          VStack(alignment: .leading, spacing: 3) {
            Text(detail.album.name).font(.headline)
            Text(
              (detail.album.artistDisplayName.map { $0 + " · " } ?? "")
                + "\(detail.album.trackCount) tracks"
                + (catalog.albumDynamic?.collectCount
                  .map { " · \($0) collected" } ?? "")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          collectAlbumButton(detail.album)
        }
        .padding(12)

        Divider()

        if detail.tracks.isEmpty {
          Text("This album lists no tracks")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(detail.tracks) { track in
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
              PlayTrackButton(
                track: track,
                tracks: detail.tracks,
                context: .album(
                  id: detail.album.id,
                  name: detail.album.name
                ),
                playback: playback,
                session: session
              )
            }
            .padding(.vertical, 3)
          }
        }
      }
    } else {
      placeholder("Open an album from Search, New Releases or an artist page")
    }
  }

  @ViewBuilder private func collectAlbumButton(_ album: Album) -> some View {
    let state = collections.albumCollectionState(for: album.id)
    let collected = state == .confirmed(true)
    Button {
      collections.setAlbumCollected(
        !collected,
        album: album,
        session: session
      )
    } label: {
      Label(
        collected ? "Remove" : "Collect",
        systemImage: collected ? "minus.circle" : "plus.circle"
      )
    }
    .disabled(loadDisabled)
    .help(
      state == .unknown
        ? "Collected state unknown; this collects the album · 1 request"
        : collected
          ? "Remove from your collected albums · 1 request"
          : "Add to your collected albums · 1 request"
    )
  }

  // MARK: - Artist

  @ViewBuilder private var artistPane: some View {
    if let detail = catalog.artist {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Artwork(
            url: detail.artist.artworkURL,
            size: 56,
            symbol: "music.microphone",
            loader: artwork
          )
          VStack(alignment: .leading, spacing: 3) {
            Text(detail.artist.name).font(.headline)
            Text(
              "\(detail.artist.albumCount) albums · "
                + "\(detail.artist.songCount) songs"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Similar Artists · 1 request", systemImage: "person.2") {
            showSimilarArtists(detail.artist)
          }
          .disabled(loadDisabled)
          .help("Loads the Similar Artists section in Discover")
          let followed =
            collections.artistFollowState(for: detail.artist.id) == .confirmed(true)
          Button(
            followed ? "Unfollow · 1 request" : "Follow · 1 request",
            systemImage: followed ? "person.badge.minus" : "person.badge.plus"
          ) {
            collections.setArtistFollowed(
              !followed,
              artist: detail.artist,
              session: session
            )
          }
          .disabled(loadDisabled)
        }
        .padding(12)

        Divider()

        List {
          Section("Top Songs") {
            ForEach(detail.hotSongs) { track in
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
                PlayTrackButton(
                  track: track,
                  tracks: detail.hotSongs,
                  context: .artist(
                    id: detail.artist.id,
                    name: detail.artist.name
                  ),
                  playback: playback,
                  session: session
                )
              }
            }
          }

          Section("Albums") {
            ForEach(catalog.artistAlbums) { album in
              HStack {
                AlbumRowLabel(album: album, loader: artwork)
                Spacer()
                Button("Open · 2 requests", systemImage: "opticaldisc") {
                  catalog.openAlbum(id: album.id, session: session)
                  pane = .album
                }
                .buttonStyle(.borderless)
                .disabled(loadDisabled)
              }
            }
            if catalog.artistAlbumsHaveMore {
              Button("Load More · 1 request", systemImage: "plus") {
                catalog.loadMoreArtistAlbums(session: session)
              }
              .buttonStyle(.borderless)
              .disabled(loadDisabled)
            }
          }
        }
      }
    } else {
      placeholder("Open an artist from Search, Top Artists or an album page")
    }
  }

  // MARK: - Browse lists

  @ViewBuilder private var newReleasesPane: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Region", selection: $catalog.newAlbumArea) {
          Text("All").tag(AlbumArea.all)
          Text("Chinese").tag(AlbumArea.chinese)
          Text("Western").tag(AlbumArea.western)
          Text("Korean").tag(AlbumArea.korean)
          Text("Japanese").tag(AlbumArea.japanese)
        }
        .fixedSize()
        .disabled(requestInFlight)
        Button("Load · 1 request", systemImage: "arrow.clockwise") {
          catalog.loadNewAlbums(reset: true, session: session)
        }
        .disabled(loadDisabled)
        Spacer()
        if catalog.newAlbumsHaveMore {
          Button("Load More · 1 request", systemImage: "plus") {
            catalog.loadNewAlbums(reset: false, session: session)
          }
          .disabled(loadDisabled)
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 12)

      if catalog.newAlbums.isEmpty {
        placeholder("Load the new releases")
      } else {
        List(catalog.newAlbums) { album in
          HStack {
            AlbumRowLabel(album: album, loader: artwork)
            Spacer()
            Button("Open · 2 requests", systemImage: "opticaldisc") {
              catalog.openAlbum(id: album.id, session: session)
              pane = .album
            }
            .buttonStyle(.borderless)
            .disabled(loadDisabled)
          }
          .padding(.vertical, 3)
        }
      }
    }
  }

  @ViewBuilder private var topArtistsPane: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Load · 1 request", systemImage: "arrow.clockwise") {
          catalog.loadTopArtists(reset: true, session: session)
        }
        .disabled(loadDisabled)
        Spacer()
        if catalog.topArtistsHaveMore {
          Button("Load More · 1 request", systemImage: "plus") {
            catalog.loadTopArtists(reset: false, session: session)
          }
          .disabled(loadDisabled)
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 12)

      if catalog.topArtists.isEmpty {
        placeholder("Load the artist chart")
      } else {
        List(catalog.topArtists) { artist in
          HStack {
            ArtistRowLabel(artist: artist, loader: artwork)
            Spacer()
            Button("Open · 2 requests", systemImage: "music.microphone") {
              catalog.openArtist(id: artist.id, session: session)
              pane = .artist
            }
            .buttonStyle(.borderless)
            .disabled(loadDisabled)
          }
          .padding(.vertical, 3)
        }
      }
    }
  }

  @ViewBuilder private func placeholder(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
