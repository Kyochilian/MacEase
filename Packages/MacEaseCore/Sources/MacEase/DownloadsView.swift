import MacEaseAppCore
import MacEaseSession
import SwiftUI

struct DownloadsView: View {
  let session: LoginCoordinator
  @Bindable var downloads: DownloadCoordinator
  let playback: PlaybackController
  let artwork: ArtworkLoader
  @State private var pendingDeletion: OfflineDownload?
  @State private var confirmsClear = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Downloads")
          .font(.headline)
        Text(ByteFormat.short(downloads.totalBytes))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("Delete All", systemImage: "trash", role: .destructive) {
          confirmsClear = true
        }
        .disabled(
          downloads.downloads.isEmpty || downloads.isDownloading
            || downloads.isMaintaining
        )
        .help("Delete every offline download for the current account")
        .accessibilityLabel("Delete all downloads for this account")
      }
      .padding(12)

      Divider()

      if downloads.downloads.isEmpty {
        ContentUnavailableView(
          "No Downloads",
          systemImage: "arrow.down.circle",
          description: Text(
            downloads.downloadCreationUnavailableReason ?? downloads.status
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(downloads.downloads) { download in
          HStack(spacing: 8) {
            TrackRowLabel(track: download.track, loader: artwork)
            Spacer()
            Text(download.actualQuality)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(download.format.uppercased())
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
            Text(ByteFormat.short(download.byteCount))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Button {
              playback.playDownloaded(download, session: session)
            } label: {
              Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(downloads.isMaintaining)
            .help("Play the saved \(download.actualQuality) file")
            .accessibilityLabel("Play downloaded \(download.track.name)")
            Button {
              pendingDeletion = download
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(downloads.isMaintaining || downloads.isDownloading)
            .help("Delete this offline download")
            .accessibilityLabel("Delete download of \(download.track.name)")
          }
          .padding(.vertical, 3)
        }
      }

      Divider()

      HStack(spacing: 8) {
        if downloads.isDownloading {
          if let progress = downloads.progress {
            ProgressView(value: progress)
              .frame(width: 120)
              .accessibilityLabel("Download progress")
              .accessibilityValue(
                progress.formatted(.percent.precision(.fractionLength(0)))
              )
          } else {
            ProgressView().controlSize(.small)
          }
          Button("Cancel") { downloads.cancelDownload() }
            .accessibilityLabel("Cancel active download")
        }
        Text(downloads.downloadCreationUnavailableReason ?? downloads.status)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(12)
    }
    .confirmationDialog(
      pendingDeletion.map { "Delete \($0.track.name)?" } ?? "Delete download?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Download", role: .destructive) {
        if let pendingDeletion { downloads.delete(pendingDeletion) }
        pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("This removes the offline file. The song remains available online.")
    }
    .confirmationDialog(
      "Delete all downloads for this account?",
      isPresented: $confirmsClear,
      titleVisibility: .visible
    ) {
      Button("Delete All Downloads", role: .destructive) {
        downloads.clearAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Temporary streaming cache data is not affected.")
    }
  }
}
