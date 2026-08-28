import CoreImage.CIFilterBuiltins
import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI

/// Native sign-in: a QR code to scan, or a texted code.
///
/// The QR image is rendered here from the address the service returned; no
/// image is fetched from anyone, and no third-party service is asked to turn
/// the address into a code.
struct NativeSignInView: View {
  @Bindable var session: LoginCoordinator
  let arbiter: OperationArbiter
  let mutate: (@escaping @MainActor () async -> SessionMutationResult) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      qrColumn
      Divider()
      phoneColumn
    }
    .padding(16)
    .disabled(arbiter.isBusy)
  }

  @ViewBuilder private var qrColumn: some View {
    VStack(spacing: 10) {
      Text("Scan to sign in")
        .font(.headline)
      if let qr = session.qrSession {
        QRCodeImage(text: qr.url.absoluteString)
          .frame(width: 180, height: 180)
        Text(qrStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(height: 32)
        Button("Cancel") { session.cancelQRLogin() }
          .buttonStyle(.borderless)
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(.quaternary)
          Image(systemName: "qrcode")
            .font(.system(size: 56))
            .foregroundStyle(.secondary)
        }
        .frame(width: 180, height: 180)
        Text("Ask for a code, then scan it with the NetEase Cloud Music app.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(height: 32)
        Button("Get a Code · 1 request", systemImage: "qrcode") {
          mutate(session.startQRLogin)
        }
      }
    }
    .frame(width: 220)
  }

  private var qrStatusText: String {
    switch session.qrStatus {
    case .waiting: "Waiting for a scan. MacEase checks every two seconds."
    case .scanned: "Scanned. Confirm the sign-in on your phone."
    case .expired: "This code expired. Ask for a new one."
    case .authorised: "Signed in."
    case .none: ""
    }
  }

  @ViewBuilder private var phoneColumn: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sign in with a texted code")
        .font(.headline)
      HStack {
        TextField("Country", text: $session.countryCode)
          .frame(width: 64)
        TextField("Phone number", text: $session.phoneNumber)
      }
      Button("Send Code · 1 request", systemImage: "message") {
        mutate(session.sendVerificationCode)
      }
      .disabled(session.phoneNumber.isEmpty)

      SecureField("Code from the text", text: $session.verificationCode)
      Button("Sign In · up to 2 requests", systemImage: "person.crop.circle.badge.checkmark") {
        mutate(session.signInWithVerificationCode)
      }
      .disabled(!session.codeWasSent || session.verificationCode.isEmpty)

      Text(
        "MacEase never asks for your NetEase password. Signing in takes one "
          + "request for the code exchange and one to confirm which account it is."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .frame(width: 280)
  }
}

/// Renders a QR code locally with Core Image.
private struct QRCodeImage: View {
  let text: String

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.none)
          .scaledToFit()
      } else {
        // Generation failing is not worth an error dialog: the address itself
        // is shown so the user can still reach it.
        Text(text)
          .font(.caption2)
          .textSelection(.enabled)
      }
    }
  }

  private var image: NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    // "M" recovers from a quarter of the code being obscured, which is what
    // the official clients use for a login code.
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: scaled.extent.size)
  }
}
