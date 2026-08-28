import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// M1-05: one classification per failure, with the sentence a person reads
/// kept apart from the detail a bug report needs. The rule that matters most
/// is that a cancelled operation is never dressed up as a network problem.

// MARK: - Cancellation is not a failure

@Test func cancellationIsNeverReportedAsANetworkProblem() {
  #expect(OperationFailure.classify(CancellationError()) == .cancelled)
  #expect(OperationFailure.classify(URLError(.cancelled)) == .cancelled)
  // A task cancelled mid-flight can surface as almost anything underneath, so
  // the caller's own view of cancellation wins over the error it caught.
  #expect(OperationFailure.classify(URLError(.timedOut), cancelled: true) == .cancelled)
  #expect(
    OperationFailure.classify(
      NeteaseServiceError(source: .http, statusCode: 500),
      cancelled: true
    ) == .cancelled
  )
}

@Test func onlyCancellationIsUnreportable() {
  #expect(!OperationFailure.cancelled.isReportable)
  #expect(OperationFailure.timedOut.isReportable)
  #expect(OperationFailure.transport.isReportable)
  #expect(OperationFailure.decode.isReportable)
}

// MARK: - Classification

@Test func aTimeoutIsDistinctFromOtherTransportFailures() {
  #expect(OperationFailure.classify(URLError(.timedOut)) == .timedOut)
  #expect(OperationFailure.classify(URLError(.notConnectedToInternet)) == .transport)
  #expect(OperationFailure.classify(URLError(.networkConnectionLost)) == .transport)
  #expect(OperationFailure.classify(NeteaseTransportError.nonHTTPResponse) == .transport)
}

@Test func httpAndServiceStatusesStaySeparate() {
  // An HTTP status means no application answer arrived; a service code means
  // one did. Collapsing them loses the sent-write distinction.
  #expect(
    OperationFailure.classify(NeteaseServiceError(source: .http, statusCode: 503))
      == .http(status: 503)
  )
  #expect(
    OperationFailure.classify(NeteaseServiceError(source: .service, statusCode: 301))
      == .service(code: 301)
  )
}

@Test func theDocumentedRiskControlCodeIsCalledOutSeparately() {
  // `-460` is the one code the endpoint registry documents as rate limiting.
  // It is separated because the answer is to stop, never to work around it.
  #expect(
    OperationFailure.classify(NeteaseServiceError(source: .service, statusCode: -460))
      == .riskControl(code: -460)
  )
  // Nothing else is assumed to mean the same thing.
  #expect(
    OperationFailure.classify(NeteaseServiceError(source: .service, statusCode: -461))
      == .service(code: -461)
  )
  // An HTTP 460 is not a service code and must not be read as one.
  #expect(
    OperationFailure.classify(NeteaseServiceError(source: .http, statusCode: -460))
      == .http(status: -460)
  )
}

@Test func decodeFailuresAreNotTransportFailures() {
  let decoding = DecodingError.dataCorrupted(
    .init(codingPath: [], debugDescription: "unexpected shape")
  )
  #expect(OperationFailure.classify(decoding) == .decode)
  #expect(OperationFailure.classify(NeteasePlaybackError.invalidResponse) == .decode)
  #expect(OperationFailure.classify(NeteaseCatalogError.invalidResponse) == .decode)
}

@Test func aRefusedResourceIsItsOwnCategory() {
  // MacEase refused the address before any request, so nothing was sent.
  #expect(
    OperationFailure.classify(NeteasePlaybackError.nonHTTPSURL("example.test"))
      == .refusedResource
  )
  #expect(
    OperationFailure.classify(NeteasePlaybackError.unapprovedHost("example.test"))
      == .refusedResource
  )
}

@Test func keychainFailuresKeepTheirStatus() {
  #expect(
    OperationFailure.classify(CredentialVaultError.keychain(-25300))
      == .credential(.keychain(-25300))
  )
  #expect(
    OperationFailure.classify(CredentialVaultError.corruptPayload)
      == .credential(.corruptPayload)
  )
}

@Test func anUnrecognisedErrorClaimsNothingMoreSpecific() {
  struct Unknown: Error {}
  #expect(OperationFailure.classify(Unknown()) == .transport)
}

// MARK: - User copy and diagnostics are separate audiences

@Test func userCopyCarriesNoCodes() {
  let failures: [OperationFailure] = [
    .cancelled, .timedOut, .transport, .http(status: 503), .service(code: 301),
    .riskControl(code: -460), .decode, .credential(.keychain(-25300)),
    .refusedResource,
  ]
  for failure in failures {
    let message = failure.userMessage(operation: "Playlist")
    #expect(!message.contains("503"))
    #expect(!message.contains("301"))
    #expect(!message.contains("-460"))
    #expect(!message.contains("-25300"))
    #expect(!message.isEmpty)
  }
}

@Test func diagnosticsCarryTheCodeAndNothingSensitive() {
  #expect(OperationFailure.http(status: 503).diagnostic == "http=503")
  #expect(OperationFailure.service(code: 301).diagnostic == "service=301")
  #expect(OperationFailure.riskControl(code: -460).diagnostic == "riskControl=-460")
  #expect(
    OperationFailure.credential(.keychain(-25300)).diagnostic
      == "keychain status=-25300"
  )
  // The refused host is deliberately absent: the diagnostic says the category,
  // and the address belongs to the resource, not to this line.
  #expect(OperationFailure.refusedResource.diagnostic == "refusedResource")
}

@Test func statusTextNamesTheOperationAndEndsWithTheDiagnostic() {
  let text = OperationFailure.http(status: 500).statusText(operation: "Daily songs")

  #expect(text.hasPrefix("Daily songs"))
  #expect(text.hasSuffix("(http=500)"))
}

@Test func riskControlTellsTheUserToStop() {
  // The one message that has to change behaviour rather than just describe it.
  let text = OperationFailure.riskControl(code: -460).userMessage(operation: "Delete")
  #expect(text.contains("rate limiting"))
  #expect(text.contains("later"))
}
