@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

package struct CloudFileMetadata: Sendable {
  package let fileURL: URL
  package let fileSize: Int64
  package let md5: String
  package let bitrate: Int
  package let title: String
  package let artist: String
  package let album: String
}

package enum CloudUploadProgress: Equatable, Sendable {
  case preparing
  case transferring(Double)
  case publishing
}

package enum NeteaseUploadError: Error, Equatable, Sendable {
  case invalidFile
  case invalidResponse
  case notImportable
  case beforePublication
}

extension NeteaseSession {
  package static func cloudFileMetadata(at url: URL) async throws -> CloudFileMetadata {
    guard url.isFileURL else { throw NeteaseUploadError.invalidFile }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0,
      size <= 2_000_000_000
    else { throw NeteaseUploadError.invalidFile }
    let asset = AVURLAsset(url: url)
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
      throw NeteaseUploadError.invalidFile
    }
    let digest = try await NeteaseCrypto.fileMD5(url)
    let items = (try? await asset.load(.commonMetadata)) ?? []
    var title = url.deletingPathExtension().lastPathComponent
    var artist = "未知艺术家"
    var album = "未知专辑"
    for item in items {
      guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
      switch item.commonKey {
      case .commonKeyTitle: title = value
      case .commonKeyArtist: artist = value
      case .commonKeyAlbumName: album = value
      default: break
      }
    }
    let duration = (try? await asset.load(.duration).seconds) ?? 0
    let rate = duration.isFinite && duration > 0 ? Double(size) * 8 / duration : 999_000
    return CloudFileMetadata(
      fileURL: url, fileSize: Int64(size),
      md5: digest,
      bitrate: Int(min(max(rate, 1), 100_000_000)), title: title, artist: artist, album: album
    )
  }

  /// cloud_upload_token + cloud_upload_complete, using one NOS allocation.
  package func uploadCloudFile(
    at fileURL: URL, credential: NeteaseCredential,
    progress: @escaping @Sendable (CloudUploadProgress) async -> Void
  ) async throws -> Int64 {
    let generation = requestGeneration(credential: credential)
    await progress(.preparing)
    let metadata: CloudFileMetadata
    do { metadata = try await Self.cloudFileMetadata(at: fileURL) } catch {
      throw NeteaseUploadError.invalidFile
    }
    var publishing = false
    do {
      try checkUploadSession(generation)
      let checked = try await eapiData(
        path: "/api/cloud/upload/check", fields: CloudCheck(metadata: metadata),
        credential: credential
      )
      let check = try JSONDecoder().decode(CloudCheckReply.self, from: checked)
      try checkUploadSession(generation)
      let bucket = "jd-musicrep-privatecloud-audio-public"
      let allocationName = fileURL.deletingPathExtension().lastPathComponent
        .components(separatedBy: .whitespacesAndNewlines).joined().replacingOccurrences(
          of: ".", with: "_")
      let allocation = try JSONDecoder().decode(
        NOSAllocation.self,
        from: await weapiData(
          path: "/api/nos/token/alloc",
          fields: NOSRequest(
            bucket: bucket, ext: fileURL.pathExtension.lowercased(), filename: allocationName,
            nos_product: 3, type: "audio", md5: metadata.md5),
          credential: credential
        )
      ).result
      guard let resourceID = allocation.resourceId, resourceID > 0 else {
        throw NeteaseUploadError.invalidResponse
      }
      if check.needUpload {
        try checkUploadSession(generation)
        let (data, response) = try await urlSession.data(
          from: URL(string: "https://wanproxy.127.net/lbs?version=1.0&bucketname=\(bucket)")!)
        guard (200..<300).contains(try Self.requireHTTPResponse(response).statusCode) else {
          throw NeteaseUploadError.invalidResponse
        }
        let lbs = try JSONDecoder().decode(NOSServers.self, from: data)
        guard
          let url = lbs.upload.lazy.compactMap({
            try? Self.nosUploadURL(server: $0, bucket: bucket, objectKey: allocation.objectKey)
          }).first
        else {
          throw NeteaseUploadError.invalidResponse
        }
        try checkUploadSession(generation)
        try await Self.uploadFile(
          at: fileURL, to: url, token: allocation.token, md5: metadata.md5,
          contentType: "application/octet-stream", configuration: urlSession.configuration
        ) { value in
          Task { await progress(.transferring(value)) }
        }
      }
      try checkUploadSession(generation)
      guard
        Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
          == metadata.fileSize
      else {
        throw NeteaseUploadError.invalidFile
      }
      let information = try await eapiData(
        path: "/api/upload/cloud/info/v2",
        fields: [
          "md5": metadata.md5, "songid": check.songID, "filename": fileURL.lastPathComponent,
          "song": metadata.title, "artist": metadata.artist, "album": metadata.album,
          "bitrate": String(metadata.bitrate), "resourceId": String(resourceID),
        ], credential: credential
      )
      let result = try JSONDecoder().decode(CloudInfoReply.self, from: information)
      guard let songID = Int64(result.songID), songID > 0 else {
        throw NeteaseUploadError.invalidResponse
      }
      try checkUploadSession(generation)
      await progress(.publishing)
      try checkUploadSession(generation)
      publishing = true
      do {
        _ = try await eapiData(
          path: "/api/cloud/pub/v2", fields: ["songid": result.songID], credential: credential)
      } catch let error as NeteaseServiceError
        where error.source == .service && error.statusCode == 201
      {
        // The Node wrapper accepts 201. Confirm the account's file before treating it as saved.
        guard generation == auxiliaryGeneration, !Task.isCancelled else {
          throw CancellationError()
        }
        _ = try await cloudSongDetail(songID: songID, credential: credential)
      }
      return songID
    } catch {
      if publishing { throw error }
      if let service = error as? NeteaseServiceError, service.source == .service { throw service }
      throw NeteaseUploadError.beforePublication
    }
  }

  package func importCloudFile(
    at fileURL: URL, matchedSongID: Int64?, credential: NeteaseCredential
  ) async throws {
    let generation = requestGeneration(credential: credential)
    let metadata = try await Self.cloudFileMetadata(at: fileURL)
    try checkUploadSession(generation)
    let songs = String(
      decoding: try JSONEncoder().encode([
        CloudImportCheck(
          md5: metadata.md5, songId: matchedSongID ?? -2, bitrate: metadata.bitrate / 1000,
          fileSize: metadata.fileSize)
      ]), as: UTF8.self)
    let checked = try await eapiData(
      path: "/api/cloud/upload/check/v2", fields: CloudImportBody(songs: songs),
      credential: credential
    )
    let result = try JSONDecoder().decode(CloudImportReply.self, from: checked)
    guard result.data.count == 1, let item = result.data.first else {
      throw NeteaseUploadError.invalidResponse
    }
    if item.upload == 1 {
      guard let id = Int64(item.songID), id > 0 else { throw NeteaseUploadError.invalidResponse }
      _ = try await cloudSongDetail(songID: id, credential: credential)
      return
    }
    guard item.upload == 0 else { throw NeteaseUploadError.notImportable }
    try checkUploadSession(generation)
    let imported = String(
      decoding: try JSONEncoder().encode([
        [
          "songId": item.songID, "bitrate": String(metadata.bitrate / 1000), "song": metadata.title,
          "artist": metadata.artist, "album": metadata.album, "fileName": fileURL.lastPathComponent,
        ]
      ]), as: UTF8.self)
    _ = try await eapiData(
      path: "/api/cloud/user/song/import", fields: CloudImportBody(songs: imported),
      credential: credential)
    guard let id = Int64(item.songID), id > 0 else { throw NeteaseUploadError.invalidResponse }
    _ = try await cloudSongDetail(songID: id, credential: credential)
  }

  package func updatePlaylistCover(playlistID: Int64, fileURL: URL, credential: NeteaseCredential)
    async throws
  {
    let generation = requestGeneration(credential: credential)
    var publishing = false
    do {
      guard fileURL.isFileURL,
        let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { throw NeteaseUploadError.invalidFile }
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString
      )
      .appendingPathExtension("jpg")
      defer { try? FileManager.default.removeItem(at: temporary) }
      guard
        let destination = CGImageDestinationCreateWithURL(
          temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
      else {
        throw NeteaseUploadError.invalidFile
      }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw NeteaseUploadError.invalidFile }
      let allocation = try JSONDecoder().decode(
        NOSAllocation.self,
        from: await weapiData(
          path: "/api/nos/token/alloc",
          fields: NOSRequest(
            bucket: "yyimgs", ext: "jpg", filename: fileURL.lastPathComponent, nos_product: 0,
            type: "other", md5: nil,
            return_body: #"{"code":200,"size":"$(ObjectSize)"}"#), credential: credential
        )
      ).result
      guard let imageID = allocation.docId, Int64(imageID).map({ $0 > 0 }) == true else {
        throw NeteaseUploadError.invalidResponse
      }
      try checkUploadSession(generation)
      let url = try Self.nosUploadURL(
        server: "https://nosup-hz1.127.net", bucket: "yyimgs", objectKey: allocation.objectKey)
      try await Self.uploadFile(
        at: temporary, to: url, token: allocation.token, md5: nil, contentType: "image/jpeg",
        configuration: urlSession.configuration
      ) { _ in }
      try checkUploadSession(generation)
      publishing = true
      _ = try await weapiData(
        path: "/api/playlist/cover/update",
        fields: ["id": String(playlistID), "coverImgId": imageID], credential: credential)
    } catch {
      if publishing { throw error }
      if let service = error as? NeteaseServiceError, service.source == .service { throw service }
      if let upload = error as? NeteaseUploadError, upload == .invalidFile { throw upload }
      throw NeteaseUploadError.beforePublication
    }
  }

  private func checkUploadSession(_ generation: UUID) throws {
    try Task.checkCancellation()
    guard generation == auxiliaryGeneration else { throw NeteaseUploadError.beforePublication }
  }

  static func nosUploadURL(server: String, bucket: String, objectKey: String) throws -> URL {
    guard var components = URLComponents(string: server),
      let host = components.host?.lowercased(), host.hasSuffix(".127.net"),
      components.user == nil, components.password == nil, components.port == nil,
      components.scheme == "https" || components.scheme == "http",
      !objectKey.isEmpty, objectKey.count <= 1024,
      objectKey.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
    else { throw NeteaseUploadError.invalidResponse }
    components.scheme = "https"
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/%?#")
    guard let key = objectKey.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw NeteaseUploadError.invalidResponse
    }
    components.percentEncodedPath = "/\(bucket)/\(key)"
    components.queryItems = [
      URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "complete", value: "true"),
      URLQueryItem(name: "version", value: "1.0"),
    ]
    guard let url = components.url else { throw NeteaseUploadError.invalidResponse }
    return url
  }

  private static func uploadFile(
    at fileURL: URL, to url: URL, token: String, md5: String?, contentType: String,
    configuration: URLSessionConfiguration,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard !token.isEmpty, token.count <= 16_384, token.utf8.allSatisfy({ (32...126).contains($0) })
    else {
      throw NeteaseUploadError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue(token, forHTTPHeaderField: "x-nos-token")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    if let md5 { request.setValue(md5, forHTTPHeaderField: "Content-MD5") }
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let delegate = NOSUploadProgress(progress: progress)
    let (data, response) = try await session.upload(
      for: request, fromFile: fileURL, delegate: delegate)
    let http = try requireHTTPResponse(response)
    guard (200..<300).contains(http.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: http.statusCode)
    }
    if !data.isEmpty {
      let reply = try JSONDecoder().decode(NOSUploadReply.self, from: data)
      if let error = reply.errCode, !error.isEmpty, error != "0" {
        throw NeteaseUploadError.invalidResponse
      }
      if let code = reply.code, code != 200 { throw NeteaseUploadError.invalidResponse }
    }
  }
}

private struct CloudCheck: Encodable, Sendable {
  let bitrate: String
  let ext = ""
  let length: Int64
  let md5: String
  let songId = "0"
  let version = 1
  init(metadata: CloudFileMetadata) {
    bitrate = String(metadata.bitrate)
    length = metadata.fileSize
    md5 = metadata.md5
  }
}
private struct CloudCheckReply: Decodable {
  let needUpload: Bool
  let songID: String
  enum CodingKeys: String, CodingKey { case needUpload, songId }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    needUpload = try c.decode(Bool.self, forKey: .needUpload)
    songID = try c.decodeIdentifier(forKey: .songId)
  }
}
private struct CloudInfoReply: Decodable {
  let songID: String
  enum CodingKeys: String, CodingKey { case songId }
  init(from decoder: any Decoder) throws {
    songID = try decoder.container(keyedBy: CodingKeys.self).decodeIdentifier(forKey: .songId)
  }
}
private struct NOSRequest: Encodable, Sendable {
  let bucket: String
  let ext: String
  let filename: String
  let local = false
  let nos_product: Int
  let type: String
  let md5: String?
  var return_body: String? = nil
}
private struct NOSAllocation: Decodable {
  let result: Allocation
  struct Allocation: Decodable {
    let token: String
    let objectKey: String
    let resourceId: Int64?
    let docId: String?
  }
}
private struct NOSServers: Decodable { let upload: [String] }
private struct NOSUploadReply: Decodable {
  let errCode: String?
  let code: Int?
  enum CodingKeys: String, CodingKey { case errCode, code }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decodeIfPresent(Int.self, forKey: .code)
    if let value = try? container.decode(Int.self, forKey: .errCode) {
      errCode = String(value)
    } else {
      errCode = try container.decodeIfPresent(String.self, forKey: .errCode)
    }
  }
}
private struct CloudImportCheck: Encodable, Sendable {
  let md5: String
  let songId: Int64
  let bitrate: Int
  let fileSize: Int64
}
private struct CloudImportBody: Encodable, Sendable {
  let uploadType = 0
  let songs: String
}
private struct CloudImportReply: Decodable {
  let data: [Item]
  struct Item: Decodable {
    let upload: Int
    let songID: String
    enum CodingKeys: String, CodingKey { case upload, songId }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      upload = try c.decode(Int.self, forKey: .upload)
      songID = try c.decodeIdentifier(forKey: .songId)
    }
  }
}
extension KeyedDecodingContainer {
  func decodeIdentifier(forKey key: Key) throws -> String {
    if let value = try? decode(Int64.self, forKey: key) { return String(value) }
    let value = try decode(String.self, forKey: key)
    guard Int64(value) != nil else { throw NeteaseUploadError.invalidResponse }
    return value
  }
}
private final class NOSUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
  let progress: @Sendable (Double) -> Void
  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    if totalBytesExpectedToSend > 0 {
      progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? { nil }
}
