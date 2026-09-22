import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

struct PlaybackBarView: View {
  let session: LoginCoordinator
  @Bindable var playback: PlaybackController
  let arbiter: OperationArbiter
  let downloads: DownloadCoordinator?
  let mediaRouter: SystemMediaRouter
  let artwork: ArtworkLoader
  @State private var scrubPosition: Double?
  @State private var showsQueue = false

  private var requestInFlight: Bool { !session.isOnline }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "music.note")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(playback.trackName ?? "Nothing playing")
            if let position = playback.queuePosition {
              Text(position)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(playback.status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if playback.phase == .playing || playback.phase == .paused {
          Text(TimeFormat.short(scrubPosition ?? playback.positionSeconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          if let duration = playback.durationSeconds {
            Slider(
              value: Binding(
                get: { min(scrubPosition ?? playback.positionSeconds, duration) },
                set: { scrubPosition = $0 }
              ),
              in: 0...duration
            ) { editing in
              if !editing {
                if let scrubPosition {
                  playback.seek(to: scrubPosition)
                }
                scrubPosition = nil
              }
            }
            .frame(width: 180)
            .help("Seek")
            Text(TimeFormat.short(duration))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        if let track = playback.currentTrack {
          DownloadTrackButton(
            track: track,
            quality: playback.quality,
            downloads: downloads,
            session: session,
            disabled: requestInFlight
          )
        }
        SystemRoutePicker()
          .frame(width: 28, height: 28)
          .help("Choose an AirPlay or system audio route")
        Picker("Quality", selection: $playback.quality) {
          ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            Text(quality.displayName).tag(quality)
          }
        }
        .fixedSize()
        .help("Applies to the next explicit Play")
        .disabled(!playback.canStartNonSessionOperation)
        if playback.canPlayAgain {
          Button(
            playback.retryResumesPlayback
              ? "Play Again" : "Restore Paused",
            systemImage: "arrow.counterclockwise"
          ) {
            playback.playAgain(session: session)
          }
          .disabled(session.account == nil)
          .help("Uses a matching download or resolves a fresh song URL")
        }
        if playback.isActive {
          Button("Stop", systemImage: "stop.fill") {
            playback.stop()
          }
        }
      }
      .padding(12)

      Divider()

      HStack(spacing: 10) {
        Button("Previous", systemImage: "backward.end.fill") {
          _ = mediaRouter.perform(AppPlaybackCommand.previous)
        }
        .disabled(!mediaRouter.canPerform(AppPlaybackCommand.previous))
        Button(
          playback.phase == .playing ? "Pause" : "Resume",
          systemImage: playback.phase == .playing ? "pause.fill" : "play.fill"
        ) {
          _ = mediaRouter.perform(.togglePlayback)
        }
        .disabled(!mediaRouter.canPerform(.togglePlayback))
        Button("Next", systemImage: "forward.end.fill") {
          _ = mediaRouter.perform(AppPlaybackCommand.next)
        }
        .disabled(!mediaRouter.canPerform(AppPlaybackCommand.next))

        Button("Up Next", systemImage: "list.bullet") {
          showsQueue.toggle()
        }
        .disabled(playback.queueSnapshot == nil)
        .popover(isPresented: $showsQueue) {
          UpNextView(playback: playback, router: mediaRouter, artwork: artwork)
        }

        Picker(
          "Mode",
          selection: Binding(
            get: { playback.playbackMode },
            set: { _ = mediaRouter.perform(.setMode($0)) }
          )
        ) {
          ForEach(PlaybackMode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .fixedSize()
        .disabled(!mediaRouter.canPerform(.setMode(playback.playbackMode)))
        .help(
          "Order after a track ends naturally; matching downloads play locally, "
            + "otherwise confirmed unavailability uses bounded downward quality recovery"
        )

        Spacer()

        Button {
          playback.isMuted.toggle()
        } label: {
          Image(
            systemName: playback.isMuted
              ? "speaker.slash.fill" : "speaker.wave.2.fill"
          )
        }
        .buttonStyle(.borderless)
        .help("Mute")
        Slider(value: $playback.volume, in: 0...1)
          .frame(width: 100)
          .help("Volume")

        Menu {
          ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
            Button("\(minutes) min") {
              playback.setSleepTimer(minutes: minutes)
            }
          }
          Button("Off") {
            playback.setSleepTimer(minutes: 0)
          }
          Divider()
          Toggle("Stop immediately at deadline", isOn: $playback.sleepStopsImmediately)
        } label: {
          Label(sleepLabel, systemImage: "moon.zzz")
        }
        .fixedSize()
        .help("Local timer; by default it lets the current track finish")
      }
      .padding(12)
    }
    // A drag session can outlive the slider when the track ends mid-drag;
    // stale scrub state would freeze the next track's displayed position.
    .onChange(of: playback.phase) {
      if playback.phase != .playing && playback.phase != .paused {
        scrubPosition = nil
      }
    }
  }

  private var sleepLabel: String {
    switch playback.sleepTimer {
    case .off:
      "Sleep Timer"
    case .armed(let deadline):
      "Sleep at " + deadline.formatted(date: .omitted, time: .shortened)
    case .finishingTrack:
      "Sleep after this track"
    }
  }

}
