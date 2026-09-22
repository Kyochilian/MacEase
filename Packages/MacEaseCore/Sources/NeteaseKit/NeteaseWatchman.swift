import Foundation
import WebKit

package enum NeteaseWritePreparationError: Error, Equatable, Sendable {
  case verificationUnavailable
}

/// The official Watchman web SDK runs in an isolated native WebKit document.
/// Only its fresh token crosses back; account cookies are never supplied.
@MainActor
final class NeteaseWatchman: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private var webView: WKWebView?
  private var continuation: CheckedContinuation<String, any Error>?
  private var deadline: Task<Void, Never>?

  func token() async throws -> String {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "verification")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        webView.navigationDelegate = self
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(45)) } catch { return }
          self?.finish(.failure(NeteaseWritePreparationError.verificationUnavailable))
        }
        webView.loadHTMLString(Self.document, baseURL: URL(string: "https://music.163.com/"))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, message.name == "verification",
      let value = message.body as? String, !value.isEmpty, value.count <= 4096,
      NeteaseCookie.isValidValue(value)
    else {
      finish(.failure(NeteaseWritePreparationError.verificationUnavailable))
      return
    }
    finish(.success(value))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    finish(.failure(NeteaseWritePreparationError.verificationUnavailable))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(.failure(NeteaseWritePreparationError.verificationUnavailable))
  }

  private func finish(_ result: Result<String, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "verification")
    webView = nil
    continuation.resume(with: result)
  }

  // register_checktoken_v2.js at d55d92cd0031d7c7746b7068faecd7ade1d354ac.
  private static let document = #"""
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <script>
    const report = value => window.webkit.messageHandlers.verification.postMessage(value || "");
    const script = document.createElement("script");
    script.src = "https://acstatic-dun.126.net/tool.min.js";
    script.onerror = () => report("");
    script.onload = () => {
      try {
        window.initWatchman({auto: true, productNumber: "YD00000558929251",
          onerror: () => report(""),
          onload: instance => {
            let requested = false;
            const request = () => {
              if (requested) return;
              requested = true;
              instance.getToken("bd5d2f973ef74cd2a61325a412ae54d9", report);
            };
            instance.getInstance().I(request);
            setTimeout(request, 15000);
          }
        });
      } catch (_) { report(""); }
    };
    document.head.appendChild(script);
    </script></body></html>
    """#
}
