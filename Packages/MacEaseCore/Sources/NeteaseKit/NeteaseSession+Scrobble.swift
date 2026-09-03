import Foundation

/// The playlist source accepted by `/api/feedback/weblog`.
///
/// Checked against `api-enhanced@a7e8d48` (`module/scrobble.js`): the endpoint
/// always sends `source: "list"`; only the real playlist id is caller data.
package struct ScrobbleContext: Equatable, Sendable {
  package let sourceID: Int64

  package init(sourceID: Int64) {
    self.sourceID = sourceID
  }
}

package enum ScrobbleRequest: Equatable, Sendable {
  case start(songID: Int64, context: ScrobbleContext)
  case finish(songID: Int64, context: ScrobbleContext, playedSeconds: Int)
}

package enum NeteaseFeedbackError: Error, Equatable, Sendable {
  case invalidResponse
}

extension NeteaseSession {
  private static let scrobblePath = "/api/feedback/weblog"
  private static let scrobbleURL = URL(
    string: "https://clientlog.music.163.com/eapi/feedback/weblog"
  )!

  package func scrobbleStart(
    songID: Int64,
    context: ScrobbleContext,
    credential: NeteaseCredential
  ) async throws {
    try await sendScrobble(
      .start(songID: songID, context: context),
      credential: credential
    )
  }

  package func scrobbleFinish(
    songID: Int64,
    context: ScrobbleContext,
    playedSeconds: Int,
    credential: NeteaseCredential
  ) async throws {
    try await sendScrobble(
      .finish(
        songID: songID,
        context: context,
        playedSeconds: max(0, playedSeconds)
      ),
      credential: credential
    )
  }

  private func sendScrobble(
    _ scrobble: ScrobbleRequest,
    credential: NeteaseCredential
  ) async throws {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.scrobbleRequest(
      scrobble,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyScrobbleAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func scrobbleRequest(
    _ scrobble: ScrobbleRequest,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    let fields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
    let header = try eapiHeaderJSON(fields)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let logs: Data
    switch scrobble {
    case .start(let songID, let context):
      logs = try encoder.encode([
        ScrobbleStartLog(
          action: "startplay",
          json: ScrobbleStartBody(
            id: songID,
            type: "song",
            mainsite: "1",
            mainsiteWeb: "1",
            content: "id=\(context.sourceID)"
          )
        )
      ])
    case .finish(let songID, let context, let playedSeconds):
      logs = try encoder.encode([
        ScrobbleFinishLog(
          action: "play",
          json: ScrobbleFinishBody(
            download: 0,
            end: "playend",
            id: songID,
            sourceId: context.sourceID,
            time: max(0, playedSeconds),
            type: "song",
            wifi: 0,
            source: "list",
            mainsite: "1",
            mainsiteWeb: "1",
            content: "id=\(context.sourceID)"
          )
        )
      ])
    }
    let logsString = String(decoding: logs, as: UTF8.self)
    let encodedLogs = String(
      decoding: try encoder.encode(logsString),
      as: UTF8.self
    )
    return try eapiFormRequest(
      path: scrobblePath,
      json: #"{"logs":\#(encodedLogs),"e_r":false,"header":\#(header)}"#,
      headerFields: fields,
      url: scrobbleURL
    )
  }

  package static func classifyScrobbleAcknowledgement(
    data: Data,
    response: HTTPURLResponse
  ) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }
    guard let code = try? JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    else { throw NeteaseFeedbackError.invalidResponse }
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
  }
}

private struct ScrobbleStartLog: Encodable {
  let action: String
  let json: ScrobbleStartBody
}

private struct ScrobbleStartBody: Encodable {
  let id: Int64
  let type: String
  let mainsite: String
  let mainsiteWeb: String
  let content: String
}

private struct ScrobbleFinishLog: Encodable {
  let action: String
  let json: ScrobbleFinishBody
}

private struct ScrobbleFinishBody: Encodable {
  let download: Int
  let end: String
  let id: Int64
  let sourceId: Int64
  let time: Int
  let type: String
  let wifi: Int
  let source: String
  let mainsite: String
  let mainsiteWeb: String
  let content: String
}
