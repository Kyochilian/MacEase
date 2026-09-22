import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

struct SessionView: View {
  @Bindable var session: LoginCoordinator
  let arbiter: OperationArbiter
  /// Non-nil when local storage is not doing its job, so a queue that is not
  /// being saved never looks like one that is.
  let storageStatus: String?
  let artwork: ArtworkLoader
  @State private var showsWebLogin = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("MacEase")
          .font(.headline)

        Label(sessionPresenceTitle, systemImage: sessionPresenceIcon)
          .foregroundStyle(
            session.storedSessionPresence == .stored ? .green : .secondary
          )

        Spacer()

        Button("Reconnect", systemImage: "checkmark.shield") {
          mutateSession(session.validateSession)
        }
        Button("Refresh Session", systemImage: "arrow.triangle.2.circlepath") {
          mutateSession(session.refreshSession)
        }
        .help("Exchanges the stored session for a fresh one")
        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
          mutateSession(session.signOutEverywhere)
        }
        .help("Revokes the session on NetEase, then clears it here")
      }
      .padding(12)
      .disabled(session.isBusy)

      Divider()

      if let account = session.account {
        VStack(alignment: .leading, spacing: 8) {
          Artwork(url: account.avatarURL, size: 64, symbol: "person.crop.circle", loader: artwork)
          Text(account.nickname ?? "Account \(account.userID)").font(.title2)
          Text(session.isOnline ? "Signed in" : "Offline — downloaded music is available")
          if let vipType = account.vipType {
            Text(vipType > 0 ? "Music membership: active" : "Standard account")
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      } else {
        NativeSignInView(session: session, arbiter: arbiter, mutate: mutateSession)
      }

      Divider()

      DisclosureGroup("Other ways to sign in", isExpanded: $showsWebLogin) {
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Button("Open Login Page", systemImage: "safari") {
              session.loadLoginPage()
            }
            Button("Save Session From Page", systemImage: "key.fill") {
              mutateSession(session.saveSession)
            }
            Button("Clear Session", systemImage: "trash") {
              mutateSession(session.clearSession)
            }
            .help("Clears locally only; Sign Out also revokes on NetEase")
            Spacer()
          }
          .padding(.vertical, 8)
          .disabled(arbiter.isBusy)

          LoginWebView(webView: session.webView)
            .frame(minHeight: 320)

          HStack(spacing: 8) {
            SecureField("Cookie header", text: $session.manualCookieHeader)
            Button("Import Session", systemImage: "square.and.arrow.down") {
              mutateSession(session.importSession)
            }
            .disabled(arbiter.isBusy)
          }
          .padding(.vertical, 8)
        }
      }
      .padding(.horizontal, 12)

      Divider()

      Text(session.status)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

      if let storageStatus {
        Label(storageStatus, systemImage: "externaldrive.badge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
      }
    }
  }

  private var sessionPresenceTitle: String {
    switch session.storedSessionPresence {
    case .unknown: "Session status unknown"
    case .absent: "Not signed in"
    case .stored: "Session stored"
    }
  }

  private var sessionPresenceIcon: String {
    switch session.storedSessionPresence {
    case .unknown: "questionmark.circle"
    case .absent: "person.crop.circle"
    case .stored: "checkmark.circle.fill"
    }
  }

  /// A session mutation only starts when the arbiter is free, so it can no
  /// longer cancel a write that has already reached the server. What happens
  /// to per-account local data follows from the account the operation left in
  /// effect, which `LoginCoordinator` reports once for every path — including
  /// a QR authorisation, which arrives long after this call has returned.
  private func mutateSession(
    _ operation: @escaping @MainActor () async -> SessionMutationResult
  ) {
    Task { _ = await operation() }
  }
}
