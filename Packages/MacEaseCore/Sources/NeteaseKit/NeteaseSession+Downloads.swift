import Foundation

extension NeteaseSession {
  /// song_download_url_v1.js, d55d92cd0031d7c7746b7068faecd7ade1d354ac.
  /// The raw HTTP response has a single data object, unlike player/url/v1.
  package func resolveDownloadURL(
    songID: Int64,
    quality: PlaybackQuality,
    credential: NeteaseCredential
  ) async throws -> SongURLResolution {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.downloadURLRequest(
        songID: songID, quality: quality, credential: credential,
        osVersion: Self.osVersion, buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp), nmtid: nmtid
      )
    }
    return try Self.classifyDownloadURL(
      data: data, response: Self.requireHTTPResponse(response),
      songID: songID, requestedQuality: quality
    )
  }

  package static func downloadURLRequest(
    songID: Int64,
    quality: PlaybackQuality,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    guard songID > 0 else { throw NeteasePlaybackError.invalidResponse }
    return try credentialledEAPIRequest(
      path: "/api/song/enhance/download/url/v1",
      body: #""id":\#(songID),"immerseType":"c51","level":"\#(quality.rawValue)""#,
      credential: credential, osVersion: osVersion, buildVersion: buildVersion,
      requestID: requestID, nmtid: nmtid
    )
  }

  package static func classifyDownloadURL(
    data: Data,
    response: HTTPURLResponse,
    songID: Int64,
    requestedQuality: PlaybackQuality
  ) throws -> SongURLResolution {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(DownloadURLPayload.self, from: data)
    guard let item = payload.data else { throw NeteasePlaybackError.invalidResponse }
    guard item.freeTrialInfo?.isMalformed != true else {
      throw NeteasePlaybackError.invalidResponse
    }
    return try classifyAudioItem(
      item, songID: songID, requestedQuality: requestedQuality, upgradeCDNToHTTPS: true)
  }
}

private struct DownloadURLPayload: Decodable {
  let data: SongURLPayload.Item?
}
