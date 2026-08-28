import Foundation
import NeteaseKit

/// Why an operation stopped.
///
/// Four coordinators each built their own status string from a raw error, so
/// the same failure read differently depending on which one hit it, and the
/// user-facing text carried a source name and a status code — detail that
/// belongs in diagnostics, not in a sentence a person reads. Classifying once
/// gives one answer per failure and keeps those two audiences apart.
///
/// The cases are the ones the code actually produces. There is no `permission`
/// case, for instance, because no evidence yet says which service codes mean
/// that; inventing one would be a guess the UI would then present as fact.
package enum OperationFailure: Equatable, Sendable {
  /// A newer intent superseded this one. Not a failure, and never shown as a
  /// network problem.
  case cancelled
  /// The request stopped at the timeout rather than being answered.
  case timedOut
  /// Nothing usable came back: no connection, or a response that is not HTTP.
  case transport
  /// An HTTP status arrived, so no application-level answer did.
  case http(status: Int)
  /// The application answered with a code other than 200.
  case service(code: Int)
  /// A response arrived and did not parse into what the contract promises.
  case decode
  /// The Keychain refused, or held something that is not a usable credential.
  case credential(CredentialVaultError)
  /// MacEase refused the resource before any request: a non-HTTPS media URL,
  /// or a host that is not on the approved list.
  case refusedResource

  /// Classifies a thrown error. `cancelled` is checked first and separately,
  /// because a cancelled task can surface as almost anything underneath and
  /// must never be reported as a network failure.
  package static func classify(
    _ error: any Error,
    cancelled: Bool = false
  ) -> OperationFailure {
    if cancelled || error is CancellationError { return .cancelled }

    switch error {
    case let error as NeteaseServiceError:
      switch error.source {
      case .http: return .http(status: error.statusCode)
      case .service: return .service(code: error.statusCode)
      }
    case let error as CredentialVaultError:
      return .credential(error)
    case let error as URLError:
      // `.cancelled` here is URLSession reporting the same supersession, not a
      // connectivity problem.
      if error.code == .cancelled { return .cancelled }
      return error.code == .timedOut ? .timedOut : .transport
    case NeteaseTransportError.nonHTTPResponse:
      return .transport
    case NeteasePlaybackError.nonHTTPSURL, NeteasePlaybackError.unapprovedHost:
      return .refusedResource
    case is DecodingError, NeteasePlaybackError.invalidResponse,
      NeteaseCatalogError.invalidResponse:
      return .decode
    default:
      // An unrecognised error is not evidence of anything more specific.
      return .transport
    }
  }

  /// Whether this ended the operation without the user asking. Cancellation is
  /// the user's own newer intent, so it is not something to report.
  package var isReportable: Bool { self != .cancelled }

  /// One sentence for a person, carrying no codes. `operation` names what was
  /// being attempted, so the same failure reads correctly wherever it occurs.
  package func userMessage(operation: String) -> String {
    switch self {
    case .cancelled:
      "\(operation) was replaced by a newer action"
    case .timedOut:
      "\(operation) timed out; try again when the connection is better"
    case .transport:
      "\(operation) could not reach NetEase"
    case .http:
      "\(operation) failed; NetEase did not answer the request"
    case .service:
      "NetEase refused \(operation.lowercased())"
    case .decode:
      "\(operation) returned something MacEase does not understand"
    case .credential:
      "\(operation) could not read the stored session"
    case .refusedResource:
      "\(operation) returned an address MacEase will not load"
    }
  }

  /// Short machine-facing detail. It carries codes but never a credential, a
  /// URL or a response body.
  package var diagnostic: String {
    switch self {
    case .cancelled: "cancelled"
    case .timedOut: "timeout"
    case .transport: "transport"
    case .http(let status): "http=\(status)"
    case .service(let code): "service=\(code)"
    case .decode: "decode"
    case .credential(let error): "keychain \(error.diagnostic)"
    case .refusedResource: "refusedResource"
    }
  }

  /// What a status line shows: the sentence, then the detail in brackets so a
  /// bug report carries the code without the sentence being written for one.
  package func statusText(operation: String) -> String {
    "\(userMessage(operation: operation)) (\(diagnostic))"
  }
}
