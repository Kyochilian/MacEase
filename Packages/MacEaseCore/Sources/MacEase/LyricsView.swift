import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

/// The in-app lyrics panel.
///
/// It follows the queue while it is open and stops when it is closed, which is
/// the request budget the coordinator enforces. The highlighted line is
/// derived from the playback clock on every tick; nothing here keeps a cursor
/// of its own that could drift out of step with what is playing.
struct LyricsView: View {
  let session: LoginCoordinator
  let playback: PlaybackController
  let lyrics: LyricsCoordinator
  let artwork: ArtworkLoader
  @Bindable var settings: AppSettings

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      body(for: lyrics.content)

      Divider()

      HStack {
        Text(lyrics.status)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(12)
    }
    .onAppear {
      lyrics.setPanelVisible(true, track: playback.currentTrack, session: session)
    }
    .onDisappear {
      lyrics.setPanelVisible(false, track: playback.currentTrack, session: session)
    }
    // The panel being open is the standing request for whatever is playing, so
    // a track change costs exactly one request while it is on screen.
    .onChange(of: playback.currentTrack?.id) {
      lyrics.load(track: playback.currentTrack, session: session)
    }
  }

  @ViewBuilder private func body(for content: LyricsCoordinator.Content) -> some View {
    switch content {
    case .document(let document):
      TimelineView(
        .animation(
          minimumInterval: 1.0 / 30.0,
          paused: playback.phase != .playing || !settings.usesVerbatimLyrics
            || document.lines.allSatisfy(\.words.isEmpty)
        )
      ) { _ in
        scroller(document, at: playback.presentationPositionSeconds)
      }
    case .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable, .idle:
      Text(lyrics.status)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private var header: some View {
    HStack {
      Artwork(url: playback.currentTrack?.artworkURL, size: 44, loader: artwork)
      VStack(alignment: .leading, spacing: 2) {
        Text(playback.currentTrack?.name ?? playback.trackName ?? "Nothing playing")
          .font(.headline)
        if let artists = playback.currentTrack?.artistDisplayName {
          Text(artists)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Toggle("Translation", isOn: $settings.showsLyricTranslation)
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Local display only; the translation was already fetched")
    }
    .padding(12)
  }

  @ViewBuilder private func scroller(_ document: Lyrics, at position: Double) -> some View {
    let current = document.lineIndex(at: position)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(Array(document.lines.enumerated()), id: \.offset) { index, entry in
            row(entry, isCurrent: index == current, at: position)
              .id(index)
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: current) {
        guard let current else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
          proxy.scrollTo(current, anchor: .center)
        }
      }
    }
  }

  @ViewBuilder private func row(
    _ entry: LyricLine,
    isCurrent: Bool,
    at position: Double
  ) -> some View {
    let text: String = entry.text.isEmpty ? " " : entry.text
    VStack(alignment: .leading, spacing: 3) {
      if settings.showsLyricRomanisation, let romanisation = entry.romanisation {
        Text(romanisation)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if isCurrent, settings.usesVerbatimLyrics, !entry.words.isEmpty {
        verbatimText(entry, at: position)
          .font(.title3.weight(.semibold))
      } else {
        Text(text)
          .font(isCurrent ? .title3.weight(.semibold) : .body)
          .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      }
      if settings.showsLyricTranslation, let translation = entry.translation {
        Text(translation)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      // Seeking is local and issues no request, so a tapped line is the
      // cheapest way to move within a track.
      playback.seek(to: entry.timeSeconds)
    }
  }

  /// One wrapping Text keeps NetEase's intentional spaces intact while each
  /// YRC word receives its state from the one playback clock.
  private func verbatimText(_ entry: LyricLine, at seconds: Double) -> Text {
    let current = entry.wordIndex(at: seconds)
    return entry.words.enumerated().reduce(Text(verbatim: "")) { text, pair in
      let (index, word) = pair
      let color: Color = if index == current {
        .accentColor
      } else if seconds >= word.endSeconds {
        .primary
      } else {
        .secondary
      }
      return text + Text(verbatim: word.text).foregroundColor(color)
    }
  }
}
