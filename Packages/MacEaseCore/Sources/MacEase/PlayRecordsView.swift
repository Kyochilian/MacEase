import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI


struct PlayRecordsView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let scrobble: ScrobbleCoordinator
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader

  private var requestInFlight: Bool { discovery.isLoading || arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Listening Rankings")
          .font(.headline)
        Text(scrobble.status)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Picker("Scope", selection: $discovery.recordScope) {
          Text("All Time").tag(PlayRecordScope.allTime)
          Text("Last Week").tag(PlayRecordScope.lastWeek)
        }
        .fixedSize()
        .disabled(requestInFlight)
        Button("Load · 1 request", systemImage: "arrow.clockwise") {
          discovery.loadRecords(session: session)
        }
        .disabled(session.account == nil || requestInFlight)
      }
      .padding(12)

      Divider()

      if discovery.records.isEmpty {
        Text(discovery.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(Array(discovery.records.enumerated()), id: \.element.track.id) {
          rank, entry in
          HStack {
            Text("\(rank + 1)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .trailing)
            TrackRowLabel(track: entry.track, loader: artwork)
            Spacer()
            Text("\(entry.playCount) plays")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            PlayTrackButton(
              track: entry.track,
              tracks: discovery.records.map(\.track),
              context: .listeningRankings,
              playback: playback,
              session: session
            )
          }
          .padding(.vertical, 3)
        }
      }
    }
  }
}

