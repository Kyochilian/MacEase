import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

/// Everything NetEase offers to listen to that the account did not assemble
/// itself: the recommendation sections, the browsable playlist catalogue, the
/// radar family, recommended new songs, the two similar-to lists, and the two
/// server-generated queues.
///
/// Every control says how many requests it costs, and none of them runs on its
/// own. The one exception is the launch-scoped prefetch of the four
/// recommendation sections, which happens once per app run in the composition
/// root, not here.
struct DiscoverView: View {
  private enum Pane: Hashable {
    case recommended
    case browse
    case radio
  }

  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let radio: RadioCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  let openPlaylist: (DiscoveredPlaylist) -> Void
  let openArtist: (Artist) -> Void
  @State private var pane: Pane = .recommended

  private var requestInFlight: Bool {
    discovery.isLoading || radio.isLoading || arbiter.isBusy
  }
  private var loadDisabled: Bool { session.account == nil || requestInFlight }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Section", selection: $pane) {
          Text("Recommended").tag(Pane.recommended)
          Text("Browse").tag(Pane.browse)
          Text("Radio").tag(Pane.radio)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Spacer()
      }
      .padding(12)

      Divider()

      switch pane {
      case .recommended: recommended
      case .browse: browse
      case .radio: radioPane
      }

      Divider()

      HStack {
        if discovery.isLoading || radio.isLoading {
          ProgressView().controlSize(.small)
        }
        Text(pane == .radio ? radio.status : discovery.status)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
      }
      .padding(12)
    }
  }

  // MARK: - Recommended

  @ViewBuilder private var recommended: some View {
    List {
      Section {
        trackRows(discovery.dailySongs, context: .dailyRecommendations)
      } header: {
        sectionHeader("Daily Songs") {
          discovery.loadDailySongs(session: session)
        }
      }

      Section {
        playlistRows(discovery.dailyPlaylists)
      } header: {
        sectionHeader("Daily Playlists") {
          discovery.loadDailyPlaylists(session: session)
        }
      }

      Section {
        playlistRows(discovery.personalized)
      } header: {
        sectionHeader("Recommended Playlists") {
          discovery.loadPersonalized(session: session)
        }
      }

      Section {
        playlistRows(discovery.toplists)
      } header: {
        sectionHeader("Toplists") {
          discovery.loadToplists(session: session)
        }
      }

      Section {
        playlistRows(discovery.radarPlaylists)
      } header: {
        sectionHeader(
          "Radar Playlists",
          cost: "up to \(DiscoveryCoordinator.radarPlaylistIDs.count) requests"
        ) {
          discovery.loadRadarPlaylists(session: session)
        }
      }

      Section {
        trackRows(discovery.newSongs, context: .recommendedNewSongs)
      } header: {
        sectionHeader("Recommended New Songs") {
          discovery.loadNewSongs(session: session)
        }
      }

      Section {
        trackRows(
          discovery.similarSongs,
          context: .similarSongs(
            seedName: discovery.similarSeedName ?? "the current track"
          )
        )
      } header: {
        HStack {
          Text(
            discovery.similarSeedName.map { "Similar to \($0)" }
              ?? "Similar Songs"
          )
          Spacer()
          Button("Load · 1 request", systemImage: "arrow.clockwise") {
            if let seed = playback.currentTrack {
              discovery.loadSimilarSongs(seed: seed, session: session)
            }
          }
          .buttonStyle(.borderless)
          .disabled(loadDisabled || playback.currentTrack == nil)
          .help("Uses the current queue track as the seed")
        }
      }

      Section {
        ForEach(discovery.similarArtists) { artist in
          HStack {
            ArtistRowLabel(artist: artist, loader: artwork)
            Spacer()
            Button("Open · 2 requests", systemImage: "music.microphone") {
              openArtist(artist)
            }
            .buttonStyle(.borderless)
            .disabled(loadDisabled)
          }
        }
      } header: {
        Text(
          discovery.similarArtistSeedName.map { "Artists like \($0)" }
            ?? "Similar Artists"
        )
        .help("Open an artist and use Similar Artists there")
      }
    }
  }

  // MARK: - Browse

  @ViewBuilder private var browse: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Category", selection: $discovery.selectedCategory) {
          ForEach(PlaylistCategory.browsable, id: \.self) { Text($0).tag($0) }
        }
        .fixedSize()
        .disabled(requestInFlight)
        Picker("Order", selection: $discovery.categoryOrder) {
          Text("Hot").tag(PlaylistOrder.hot)
          Text("New").tag(PlaylistOrder.new)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(requestInFlight)
        Button("Load · 1 request", systemImage: "arrow.clockwise") {
          discovery.loadCategoryPlaylists(reset: true, session: session)
        }
        .disabled(loadDisabled)
        Spacer()
        Picker("Highest rated", selection: $discovery.selectedHighQualityCategory) {
          ForEach(PlaylistCategory.highQuality, id: \.self) { Text($0).tag($0) }
        }
        .fixedSize()
        .disabled(requestInFlight)
        Button("Load Highest Rated · 1 request", systemImage: "star") {
          discovery.loadHighQualityPlaylists(reset: true, session: session)
        }
        .disabled(loadDisabled)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 12)

      if discovery.categoryPlaylists.isEmpty
        && discovery.highQualityPlaylists.isEmpty
      {
        Text("Pick a category and load it")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          Section {
            playlistRows(discovery.categoryPlaylists)
            if discovery.categoryHasMore {
              Button("Load More · 1 request", systemImage: "plus") {
                discovery.loadCategoryPlaylists(reset: false, session: session)
              }
              .buttonStyle(.borderless)
              .disabled(loadDisabled)
            }
          } header: {
            Text("\(discovery.selectedCategory) Playlists")
          }

          Section {
            playlistRows(discovery.highQualityPlaylists)
            if discovery.highQualityHasMore {
              Button("Load More · 1 request", systemImage: "plus") {
                discovery.loadHighQualityPlaylists(reset: false, session: session)
              }
              .buttonStyle(.borderless)
              .disabled(loadDisabled)
            }
          } header: {
            Text("Highest Rated · \(discovery.selectedHighQualityCategory)")
          }
        }
      }
    }
  }

  // MARK: - Radio

  @ViewBuilder private var radioPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button("Start Personal FM · 1 request", systemImage: "dot.radiowaves.left.and.right") {
          radio.startPersonalFM(session: session)
        }
        .disabled(loadDisabled)
        .help("Plays a queue NetEase generates for your account")
        if radio.isPlayingFM {
          Button("Not Interested · 1 request", systemImage: "hand.thumbsdown") {
            radio.trashCurrentFMSong(session: session)
          }
          .disabled(loadDisabled || radio.currentFMTrack == nil)
          .help(
            "Tells NetEase not to play this song on the radio again. "
              + "This is not the same as unliking it."
          )
        }
        Spacer()
      }

      if let failed = radio.failedTrash {
        Label(
          "\(failed.name) was not removed; it is still playing and the button "
            + "will try again",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if radio.isPlayingFM, let track = radio.currentFMTrack {
        HStack(spacing: 8) {
          TrackRowLabel(track: track, loader: artwork)
          Spacer()
          LikeButton(
            track: track,
            library: library,
            session: session,
            disabled: requestInFlight
          )
        }
      }

      Divider()

      heartbeat

      Spacer()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Heartbeat mode needs a song and the playlist it was opened from. Only the
  /// library's open playlist supplies both, so the control appears there and
  /// nowhere else; there is no id to invent when it is missing.
  @ViewBuilder private var heartbeat: some View {
    if let playlist = library.selectedPlaylist,
      let seed = heartbeatSeed(in: playlist)
    {
      HStack {
        Button("Start Heartbeat Mode · 1 request", systemImage: "heart.circle") {
          radio.startHeartbeatMode(
            seed: seed,
            playlistID: playlist.id,
            session: session
          )
        }
        .disabled(loadDisabled)
        .help("Builds a queue from \(seed.name) in \(playlist.name)")
        Spacer()
      }
    } else {
      Label(
        "Heartbeat mode needs a song from one of your open playlists. Open a "
          + "playlist in Library and play a track from it first.",
        systemImage: "info.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  /// The seed is the track playing from that playlist, or its first track when
  /// nothing from it is playing. Both are songs the playlist actually holds,
  /// which is what the contract requires.
  private func heartbeatSeed(in playlist: UserPlaylist) -> Track? {
    if playback.queueContext == .playlist(id: playlist.id, name: playlist.name),
      let current = playback.currentTrack
    {
      return current
    }
    return library.tracks.first
  }

  // MARK: - Shared rows

  private func sectionHeader(
    _ title: String,
    cost: String = "1 request",
    load: @escaping () -> Void
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      Button("Load · \(cost)", systemImage: "arrow.clockwise", action: load)
        .buttonStyle(.borderless)
        .disabled(loadDisabled)
    }
  }

  private func trackRows(
    _ tracks: [Track],
    context: PlaybackContext
  ) -> some View {
    ForEach(tracks) { track in
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
          context: context,
          playback: playback,
          session: session
        )
      }
    }
  }

  private func playlistRows(_ playlists: [DiscoveredPlaylist]) -> some View {
    ForEach(playlists) { playlist in
      HStack {
        PlaylistRowLabel(playlist: playlist, loader: artwork)
        Spacer()
        Button("Open · up to 2 requests", systemImage: "music.note.list") {
          openPlaylist(playlist)
        }
        .buttonStyle(.borderless)
        .disabled(loadDisabled)
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
        .disabled(loadDisabled)
        .help("Subscribe to this playlist · 1 request")
      }
    }
  }
}
