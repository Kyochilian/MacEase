import MacEaseAppCore
import NeteaseKit
import SwiftUI

/// A live projection of PlaybackController's queue. Every action carries the
/// account and revision that produced the row, so an old popover cannot edit a
/// queue that replaced it.
struct UpNextView: View {
  @Bindable var playback: PlaybackController
  let router: SystemMediaRouter
  let artwork: ArtworkLoader

  var body: some View {
    Group {
      if let snapshot = playback.queueSnapshot {
        VStack(spacing: 0) {
          header(snapshot)
          Divider()
          List {
            Section("Now Playing") {
              row(snapshot.current, current: true, snapshot: snapshot)
            }
            if !snapshot.upcoming.isEmpty {
              Section("Up Next") {
                ForEach(snapshot.upcoming) { track in
                  row(track, current: false, snapshot: snapshot)
                }
              }
            }
          }
          .listStyle(.inset)
          if !snapshot.allowsEditing {
            Divider()
            Text("This dynamic queue is managed by Personal FM.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(10)
          }
        }
      } else {
        ContentUnavailableView(
          "Queue Is Empty",
          systemImage: "list.bullet",
          description: Text("Play a track to create a queue.")
        )
      }
    }
    .frame(width: 380, height: 480)
  }

  private func header(_ snapshot: PlaybackQueueSnapshot) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Up Next").font(.headline)
        Text("\(snapshot.mode.label) · \(snapshot.context.label)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Clear Upcoming", systemImage: "clear") {
        _ = router.perform(
          .clearUpcoming(
            accountID: snapshot.accountID,
            revision: snapshot.revision
          )
        )
      }
      .disabled(!snapshot.allowsEditing || snapshot.upcoming.isEmpty)
    }
    .padding(12)
  }

  private func row(
    _ track: Track,
    current: Bool,
    snapshot: PlaybackQueueSnapshot
  ) -> some View {
    HStack(spacing: 8) {
      if current {
        queueLabel(track)
      } else {
        Button {
          _ = router.perform(
            .playQueueEntry(
              songID: track.id,
              accountID: snapshot.accountID,
              revision: snapshot.revision
            )
          )
        } label: {
          queueLabel(track)
        }
        .buttonStyle(.plain)
        .disabled(!snapshot.allowsEditing)
      }
      Spacer(minLength: 4)
      if current {
        Image(systemName: playback.phase == .playing ? "waveform" : "pause.fill")
          .foregroundStyle(.secondary)
          .accessibilityLabel("Current track")
      }
      Button {
        _ = router.perform(
          .removeQueueEntry(
            songID: track.id,
            accountID: snapshot.accountID,
            revision: snapshot.revision
          )
        )
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .disabled(!snapshot.allowsEditing)
      .help(current ? "Remove the current track" : "Remove from Up Next")
      .accessibilityLabel("Remove \(track.name) from the queue")
    }
    .padding(.vertical, 2)
  }

  private func queueLabel(_ track: Track) -> some View {
    HStack(spacing: 8) {
      Artwork(url: track.artworkURL, loader: artwork)
      TrackLabel(track: track)
    }
    .contentShape(Rectangle())
  }
}
