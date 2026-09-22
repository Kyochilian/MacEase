import Foundation

/// Source associations carried by native listening logs. A standalone play
/// omits source fields instead of inventing a playlist or recommendation ID.
package struct ScrobbleContext: Equatable, Sendable {
  // Official web core_10d873a78248398203fe1fce52f44350.js: bMu8a and Rd6e.
  package enum Source: String, Sendable {
    case playlist = "list"
    case album, artist, song, search
    case recommendations = "dailySongRecommend"
  }
  package let sourceID: Int64?
  package let source: Source?
  package let downloaded: Bool
  package var end: ScrobbleEnd = .completed

  package init(sourceID: Int64? = nil, source: Source? = nil, downloaded: Bool = false) {
    self.sourceID = sourceID
    self.source = source ?? (sourceID == nil ? nil : .playlist)
    self.downloaded = downloaded
  }
}

package enum ScrobbleEnd: String, Sendable {
  case completed = "playend"
  case interrupted = "interrupt"
  case stopped = "ui"
  case failed = "exception"
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
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.scrobbleRequest(
        scrobble,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
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
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    let fields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
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
            content: context.sourceID.map { "id=\($0)" } ?? ""
          )
        )
      ])
    case .finish(let songID, let context, let playedSeconds):
      logs = try encoder.encode([
        ScrobbleFinishLog(
          action: "play",
          json: ScrobbleFinishBody(
            download: context.downloaded ? 1 : 0,
            end: context.end.rawValue,
            id: songID,
            sourceId: context.sourceID,
            time: max(0, playedSeconds),
            type: "song",
            wifi: 0,
            source: context.source?.rawValue,
            mainsite: "1",
            mainsiteWeb: "1",
            content: context.sourceID.map { "id=\($0)" } ?? ""
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
  let sourceId: Int64?
  let time: Int
  let type: String
  let wifi: Int
  let source: String?
  let mainsite: String
  let mainsiteWeb: String
  let content: String
}
