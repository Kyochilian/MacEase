import Foundation

package enum PlaylistMetadataEdit: Equatable, Sendable {
  case description(String)
  case tags([String])
}

extension NeteaseSession {
  func eapiData<Fields: Encodable & Sendable>(
    path: String, fields: Fields, credential: NeteaseCredential
  ) async throws -> Data {
    let timestamp = Date().timeIntervalSince1970
    let json = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.credentialledEAPIRequest(
        path: path, body: String(json.dropFirst().dropLast()), credential: credential,
        osVersion: Self.osVersion, buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp), nmtid: nmtid
      )
    }
    try Self.requireSuccess(data: data, response: Self.requireHTTPResponse(response))
    return data
  }

  func weapiData<Fields: Encodable & Sendable>(
    path: String, fields: Fields, credential: NeteaseCredential
  ) async throws -> Data {
    let encoded = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    let body = String(encoded.dropFirst().dropLast())
    let json =
      "{" + body + (body.isEmpty ? "" : ",")
      + #""csrf_token":\#(try Self.csrfJSONValue(credential)),"e_r":false}"#
    let (data, response) = try await send(credential: credential) { _ in
      guard let url = URL(string: "https://music.163.com/weapi/" + path.dropFirst("/api/".count))
      else {
        throw NeteaseTransportError.invalidURL
      }
      return Self.weapiRequest(
        url: url, parameters: try Self.weapiParameters(json: json, secretKey: nil),
        credential: credential, platformContext: true
      )
    }
    try Self.requireSuccess(data: data, response: Self.requireHTTPResponse(response))
    return data
  }

  /// The three updates have separate contracts; an omitted field is never encoded as empty.
  package func updatePlaylistMetadata(
    playlistID: Int64, edit: PlaylistMetadataEdit, credential: NeteaseCredential
  ) async throws {
    guard playlistID > 0 else { throw NeteaseWritePreparationError.verificationUnavailable }
    let path: String
    let fields: [String: String]
    switch edit {
    case .description(let description):
      guard description.count <= 1000 else {
        throw NeteaseWritePreparationError.verificationUnavailable
      }
      path = "/api/playlist/desc/update"
      fields = ["id": String(playlistID), "desc": description]
    case .tags(let tags):
      guard tags.count <= 3, tags.allSatisfy({ !$0.isEmpty && !$0.contains(";") }) else {
        throw NeteaseWritePreparationError.verificationUnavailable
      }
      path = "/api/playlist/tags/update"
      fields = ["id": String(playlistID), "tags": tags.joined(separator: ";")]
    }
    _ = try await eapiData(path: path, fields: fields, credential: credential)
  }

  package func reorderPlaylists(ids: [Int64], credential: NeteaseCredential) async throws {
    guard !ids.isEmpty, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else {
      throw NeteaseWritePreparationError.verificationUnavailable
    }
    let ids = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
    _ = try await weapiData(
      path: "/api/playlist/order/update", fields: ["ids": ids], credential: credential)
  }

  package func reorderPlaylistTracks(playlistID: Int64, ids: [Int64], credential: NeteaseCredential)
    async throws
  {
    guard playlistID > 0, !ids.isEmpty, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count
    else {
      throw NeteaseWritePreparationError.verificationUnavailable
    }
    let ids = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
    _ = try await eapiData(
      path: "/api/playlist/manipulate/tracks",
      fields: ["pid": String(playlistID), "trackIds": ids, "op": "update"], credential: credential
    )
  }
}
