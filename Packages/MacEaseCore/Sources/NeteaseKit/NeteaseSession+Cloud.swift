import Foundation

extension NeteaseSession {
  package func cloudLyrics(userID: Int64, songID: Int64, credential: NeteaseCredential) async throws
    -> Lyrics
  {
    struct Parameters: Encodable, Sendable {
      let userId: Int64
      let songId: Int64
      let lv = -1
      let kv = -1
    }
    struct Payload: Decodable { let lrc: String }
    let data = try await eapiData(
      path: "/api/cloud/lyric/get", fields: Parameters(userId: userID, songId: songID),
      credential: credential)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    return LyricsParser.parse(lrc: payload.lrc, translation: nil, romanisation: nil)
  }

  package func cloudSongDetail(songID: Int64, credential: NeteaseCredential) async throws
    -> CloudSong
  {
    struct Parameters: Encodable, Sendable { let songIds: [String] }
    struct Payload: Decodable { let data: [CloudPayload.Item] }
    let data = try await weapiData(
      path: "/api/v1/cloud/get/byids", fields: Parameters(songIds: [String(songID)]),
      credential: credential)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    guard let item = payload.data.first(where: { $0.songId == songID }) else {
      throw NeteaseCatalogError.invalidResponse
    }
    return item.song
  }

  package func matchCloudSong(
    songID: Int64, matchedSongID: Int64, userID: Int64, credential: NeteaseCredential
  ) async throws {
    guard songID > 0, matchedSongID >= 0, userID > 0 else { throw NeteaseUploadError.invalidFile }
    _ = try await weapiData(
      path: "/api/cloud/user/song/match",
      fields: [
        "userId": String(userID), "songId": String(songID), "adjustSongId": String(matchedSongID),
      ], credential: credential)
  }

  package func resolveCloudURL(
    songID: Int64, quality: PlaybackQuality, credential: NeteaseCredential
  ) async throws -> SongURLResolution {
    // The upstream spelling is dowonload. Its raw response carries name/url/size at the top level.
    let data = try await eapiData(
      path: "/api/cloud/dowonload", fields: ["songId": String(songID)], credential: credential)
    let file = try JSONDecoder().decode(CloudDownloadPayload.self, from: data)
    guard let size = file.size.value, size > 0,
      var parts = URLComponents(string: file.url),
      let host = parts.host?.lowercased(),
      NeteaseResourceHost.isApproved(host)
        || host == "jd-musicrep-privatecloud-audio-public.nos-jd.163yun.com",
      parts.scheme == "https" || parts.scheme == "http",
      parts.user == nil, parts.password == nil
    else { throw NeteasePlaybackError.invalidResponse }
    parts.scheme = "https"
    guard let url = parts.url else { throw NeteasePlaybackError.invalidResponse }
    let formats = ["mp3", "flac", "m4a", "aac", "wav", "aiff", "alac"]
    let extensionName = url.pathExtension.lowercased()
    let format =
      formats.contains(extensionName)
      ? extensionName : (file.name as NSString).pathExtension.lowercased()
    guard formats.contains(format) else { throw NeteasePlaybackError.invalidResponse }
    return .resolved(
      ResolvedAudioAsset(
        songID: songID, url: url, sourceScheme: "https", requestedQuality: quality,
        actualQuality: "Original", format: format, bitRate: nil, byteCount: size,
        expiresIn: nil, fee: nil, trial: false
      ))
  }
}

private struct CloudDownloadPayload: Decodable {
  let name: String
  let url: String
  let size: LenientInt64
}
