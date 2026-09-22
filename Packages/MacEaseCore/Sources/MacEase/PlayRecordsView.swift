import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

struct PlayRecordsView: View {
  private enum Mode: String, CaseIterable {
    case songs = "Recent Songs"
    case albums = "Recent Albums"
    case playlists = "Recent Playlists"
    case local = "On This Mac"
    case rankings = "Listening Rankings"
  }
  @Environment(\.openURL) private var openURL
  @State private var mode: Mode = .songs
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let scrobble: ScrobbleCoordinator
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("History", selection: $mode) {
          ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.fixedSize()
        if mode == .rankings {
          Picker("Scope", selection: $discovery.recordScope) {
            Text("All Time").tag(PlayRecordScope.allTime)
            Text("Last Week").tag(PlayRecordScope.lastWeek)
          }.fixedSize()
        }
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") { reload() }
          .disabled(!session.isOnline || discovery.isLoading || mode == .local)
      }.padding(12)
      Divider()
      switch mode {
      case .local:
        List(discovery.localHistory) { entry in
          HStack {
            TrackRowLabel(track: entry.track, loader: artwork)
            Spacer()
            Text(entry.context.label).font(.caption).foregroundStyle(.secondary)
            timestamp(entry.playedAt)
            PlayTrackButton(
              track: entry.track, tracks: discovery.localHistory.map(\.track),
              context: .recentListening, playback: playback, session: session)
          }
        }
      case .rankings:
        List(Array(discovery.records.enumerated()), id: \.element.track.id) { rank, entry in
          HStack {
            Text("\(rank + 1)").font(.caption.monospacedDigit())
            TrackRowLabel(track: entry.track, loader: artwork)
            Spacer()
            Text("\(entry.playCount) plays").font(.caption)
            PlayTrackButton(
              track: entry.track, tracks: discovery.records.map(\.track),
              context: .listeningRankings, playback: playback, session: session)
          }
        }
      case .songs, .albums, .playlists:
        List(discovery.recentMusic) { entry in
          HStack {
            switch entry.resource {
            case .song(let track):
              TrackRowLabel(track: track, loader: artwork)
              Spacer()
              timestamp(entry.playedAt)
              PlayTrackButton(
                track: track, tracks: recentSongs, context: .recentListening, playback: playback,
                session: session)
            case .album(let album):
              AlbumRowLabel(album: album, loader: artwork)
              Spacer()
              timestamp(entry.playedAt)
              Button("Open") { openURL(NeteaseMusicLink.album(album.id).url) }
            case .playlist(let playlist):
              PlaylistRowLabel(playlist: playlist, loader: artwork)
              Spacer()
              timestamp(entry.playedAt)
              Button("Open") { openURL(NeteaseMusicLink.playlist(playlist.id).url) }
            }
          }
        }
      }
      Divider()
      HStack {
        if discovery.isLoading { ProgressView().controlSize(.small) }
        Text(discovery.historyDiagnostic ?? discovery.status).font(.caption).foregroundStyle(
          .secondary)
        Spacer()
      }.padding(12)
    }
    .task(id: "\(session.account?.userID ?? 0)-\(mode.rawValue)") { reload() }
  }

  private var recentSongs: [Track] {
    discovery.recentMusic.compactMap {
      if case .song(let track) = $0.resource { track } else { nil }
    }
  }
  private func timestamp(_ date: Date) -> some View {
    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(
      .secondary)
  }
  private func reload() {
    switch mode {
    case .local: discovery.cancelLoading()
    case .songs: discovery.loadRecentMusic(kind: .songs, session: session)
    case .albums: discovery.loadRecentMusic(kind: .albums, session: session)
    case .playlists: discovery.loadRecentMusic(kind: .playlists, session: session)
    case .rankings:
      discovery.cancelLoading()
      discovery.loadRecords(session: session)
    }
  }
}
