import Foundation
import OSLog

/// One network transaction or the complete request. Never includes query,
/// headers, body, cookies, account IDs, or an error's localized description.
package struct RequestDiagnostic: Sendable {
  package let id: UUID
  package let phase: String
  package let host: String
  package let path: String
  package var totalMS: Double? = nil
  package var preparationMS: Double? = nil
  package var dnsMS: Double? = nil
  package var connectMS: Double? = nil
  package var tlsMS: Double? = nil
  package var sendMS: Double? = nil
  package var firstByteMS: Double? = nil
  package var receiveMS: Double? = nil
  package var status: Int? = nil
  package var errorCode: Int? = nil
  package var bytes: Int64 = 0
  package var reused: Bool? = nil
  package var proxy: Bool? = nil
  package var protocolName: String? = nil

  private static let logger = Logger(subsystem: "com.macease.app", category: "API")

  package static func log(_ event: Self) {
    logger.info("\(event.line, privacy: .public)")
  }

  package var line: String {
    func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
    return "id=\(id) phase=\(phase) host=\(host) path=\(path)"
      + " total_ms=\(ms(totalMS)) preparation_ms=\(ms(preparationMS))"
      + " dns_ms=\(ms(dnsMS)) connect_ms=\(ms(connectMS)) tls_ms=\(ms(tlsMS))"
      + " send_ms=\(ms(sendMS)) first_byte_ms=\(ms(firstByteMS)) receive_ms=\(ms(receiveMS))"
      + " status=\(status ?? 0) error=\(errorCode ?? 0) bytes=\(bytes)"
      + " reused=\(reused.map(String.init) ?? "-") proxy=\(proxy.map(String.init) ?? "-") protocol=\(protocolName ?? "-")"
  }
}

final class RequestDiagnostics: NSObject, URLSessionTaskDelegate, Sendable {
  let id = UUID()
  let request: URLRequest
  let emit: @Sendable (RequestDiagnostic) -> Void

  init(request: URLRequest, emit: @escaping @Sendable (RequestDiagnostic) -> Void) {
    self.request = request
    self.emit = emit
  }

  func event(phase: String) -> RequestDiagnostic {
    RequestDiagnostic(
      id: id, phase: phase, host: request.url?.host ?? "-",
      path: request.url?.path ?? "-")
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    for transaction in metrics.transactionMetrics {
      var event = event(phase: "transaction")
      func ms(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end else { return nil }
        return end.timeIntervalSince(start) * 1000
      }
      event.dnsMS = ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
      event.connectMS = ms(transaction.connectStartDate, transaction.connectEndDate)
      event.tlsMS = ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
      event.sendMS = ms(transaction.requestStartDate, transaction.requestEndDate)
      event.firstByteMS = ms(transaction.requestEndDate, transaction.responseStartDate)
      event.receiveMS = ms(transaction.responseStartDate, transaction.responseEndDate)
      event.status = (transaction.response as? HTTPURLResponse)?.statusCode
      event.bytes = transaction.countOfResponseBodyBytesReceived
      event.reused = transaction.isReusedConnection
      event.proxy = transaction.isProxyConnection
      event.protocolName = transaction.networkProtocolName
      emit(event)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
