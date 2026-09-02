import Foundation

/// Where a sign-in has got to.
///
/// Polling a QR code is the one place MacEase repeats a request without the
/// user pressing anything, and it is the user who started it by choosing QR
/// sign-in. The states are the ones the endpoint reports, so nothing here is
/// inferred from a timeout or a guess.
package enum QRLoginStatus: Equatable, Sendable {
  /// The code is past its lifetime. A new key is needed; polling this one
  /// again can only keep returning this.
  case expired
  /// Nobody has scanned it yet.
  case waiting
  /// Scanned, waiting for the phone to confirm.
  case scanned
  /// Confirmed, and the response carried a usable session.
  case authorised(NeteaseCredential)
}

/// A QR sign-in in progress: the key the service issued and the address to
/// draw as a code.
package struct QRLoginSession: Equatable, Sendable {
  package let key: String
  package let url: URL

  package init(key: String, url: URL) {
    self.key = key
    self.url = url
  }
}

package enum NeteaseAuthError: Error, Equatable, Sendable {
  case invalidResponse
  /// The service accepted the exchange but returned no usable session cookie.
  case noSessionInResponse
  case invalidPhoneNumber
}

/// Sign-in, sign-out and session-refresh endpoints, plus the account's own
/// collections. Kept apart from `NeteaseSession.swift`, which owns the
/// playback and catalogue paths.
extension NeteaseSession {
  private static let qrKeyEndpoint = "/api/login/qrcode/unikey"
  private static let qrCheckEndpoint = "/api/login/qrcode/client/login"
  private static let logoutEndpoint = "/api/logout"
  private static let refreshEndpoint = "/api/login/token/refresh"
  private static let playlistPrivacyEndpoint = "/api/playlist/update/privacy"

  private static let captchaURL = URL(
    string: "https://music.163.com/weapi/sms/captcha/sent"
  )!
  private static let cellphoneLoginURL = URL(
    string: "https://music.163.com/weapi/w/login/cellphone"
  )!
  private static let albumSublistURL = URL(
    string: "https://music.163.com/weapi/album/sublist"
  )!
  private static let artistSublistURL = URL(
    string: "https://music.163.com/weapi/artist/sublist"
  )!
  private static let cloudURL = URL(
    string: "https://music.163.com/weapi/v1/cloud/get"
  )!
  private static let cloudDeleteURL = URL(
    string: "https://music.163.com/weapi/cloud/del"
  )!
  private static let albumSubscribeURL = URL(
    string: "https://music.163.com/weapi/album/sub"
  )!
  private static let albumUnsubscribeURL = URL(
    string: "https://music.163.com/weapi/album/unsub"
  )!
  private static let artistSubscribeURL = URL(
    string: "https://music.163.com/weapi/artist/sub"
  )!
  private static let artistUnsubscribeURL = URL(
    string: "https://music.163.com/weapi/artist/unsub"
  )!

  static func eapiURL(_ path: String) -> URL? {
    URL(
      string: "https://interfacepc.music.163.com/eapi/"
        + path.dropFirst("/api/".count)
    )
  }

  // MARK: - QR sign-in

  /// Asks for a new sign-in key and builds the address the phone will scan
  /// (1 request). The address is assembled locally; there is no endpoint for
  /// it, and no image is fetched from anyone.
  package func beginQRLogin() async throws -> QRLoginSession {
    let request = try Self.qrKeyRequest()
    let (data, response) = try await urlSession.data(for: request)
    let key = try Self.classifyQRKey(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
    guard
      var components = URLComponents(string: "https://music.163.com/login")
    else { throw NeteaseAuthError.invalidResponse }
    components.queryItems = [URLQueryItem(name: "codekey", value: key)]
    guard let url = components.url else { throw NeteaseAuthError.invalidResponse }
    return QRLoginSession(key: key, url: url)
  }

  /// One poll of a QR sign-in (1 request). The caller decides the interval and
  /// when to stop; nothing here schedules itself.
  package func pollQRLogin(key: String) async throws -> QRLoginStatus {
    let request = try Self.qrCheckRequest(key: key)
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyQRPoll(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func qrKeyRequest() throws -> URLRequest {
    try anonymousEAPIRequest(path: qrKeyEndpoint, body: #""type":3"#)
  }

  package static func qrCheckRequest(key: String) throws -> URLRequest {
    let encoded = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
    return try anonymousEAPIRequest(
      path: qrCheckEndpoint,
      body: #""key":\#(encoded),"type":3"#
    )
  }

  package static func classifyQRKey(
    data: Data,
    response: HTTPURLResponse
  ) throws -> String {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }
    let payload = try JSONDecoder().decode(QRKeyPayload.self, from: data)
    guard payload.code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: payload.code)
    }
    guard let unikey = payload.unikey, !unikey.isEmpty else {
      throw NeteaseAuthError.invalidResponse
    }
    return unikey
  }

  /// 800/801/802/803 are this endpoint's normal answers, not failures: they
  /// mean expired, waiting, scanned and authorised. Treating them as service
  /// errors would make an unscanned code look like an outage.
  package static func classifyQRPoll(
    data: Data,
    response: HTTPURLResponse
  ) throws -> QRLoginStatus {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }
    let code = try JSONDecoder().decode(ServiceCode.self, from: data).code
    switch code {
    case 800: return .expired
    case 801: return .waiting
    case 802: return .scanned
    case 803:
      guard let credential = credential(fromSetCookie: response) else {
        throw NeteaseAuthError.noSessionInResponse
      }
      return .authorised(credential)
    default:
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
  }

  // MARK: - SMS sign-in

  /// Asks the service to text a code to `phone` (1 request).
  package func sendLoginCode(
    phone: String,
    countryCode: String = "86"
  ) async throws {
    let request = try Self.captchaRequest(phone: phone, countryCode: countryCode)
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  /// Exchanges a texted code for a session (1 request).
  ///
  /// MacEase only ever signs in with a code. The password form of this
  /// endpoint would mean holding the user's NetEase password long enough to
  /// hash it, which a third-party client has no business doing when the
  /// service offers this instead.
  package func signIn(
    phone: String,
    code: String,
    countryCode: String = "86"
  ) async throws -> NeteaseCredential {
    let request = try Self.cellphoneLoginRequest(
      phone: phone,
      code: code,
      countryCode: countryCode
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyCellphoneLogin(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func captchaRequest(
    phone: String,
    countryCode: String,
    secretKey: String? = nil
  ) throws -> URLRequest {
    guard isPlausiblePhoneNumber(phone), isPlausibleCountryCode(countryCode) else {
      throw NeteaseAuthError.invalidPhoneNumber
    }
    // weapi always carries `csrf_token`. Before sign-in there is no `__csrf`
    // cookie to derive it from, so the reference implementation sends an empty
    // string rather than omitting the field, and so does this.
    let json =
      #"{"ctcode":"\#(countryCode)","secrete":"music_middleuser_pclogin","#
      + #""cellphone":"\#(phone)","csrf_token":""}"#
    return try anonymousWeAPIRequest(
      url: captchaURL,
      json: json,
      secretKey: secretKey
    )
  }

  package static func cellphoneLoginRequest(
    phone: String,
    code: String,
    countryCode: String,
    secretKey: String? = nil
  ) throws -> URLRequest {
    guard
      isPlausiblePhoneNumber(phone),
      isPlausibleCountryCode(countryCode),
      isPlausibleVerificationCode(code)
    else {
      throw NeteaseAuthError.invalidPhoneNumber
    }
    let json =
      #"{"type":"1","https":"true","phone":"\#(phone)","#
      + #""countrycode":"\#(countryCode)","captcha":"\#(code)","#
      + #""remember":"true","secureCaptcha":"","csrf_token":""}"#
    return try anonymousWeAPIRequest(
      url: cellphoneLoginURL,
      json: json,
      secretKey: secretKey
    )
  }

  package static func classifyCellphoneLogin(
    data: Data,
    response: HTTPURLResponse
  ) throws -> NeteaseCredential {
    try classifyWriteAcknowledgement(data: data, response: response)
    guard let credential = credential(fromSetCookie: response) else {
      throw NeteaseAuthError.noSessionInResponse
    }
    return credential
  }

  // MARK: - Sign-out and refresh

  /// Ends the session on the server (1 request).
  ///
  /// Deleting the Keychain item alone leaves the cookie valid for anyone
  /// holding it. This is what actually revokes it, so the local delete follows
  /// the server's acknowledgement rather than standing in for it.
  package func signOut(credential: NeteaseCredential) async throws {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.logoutRequest(
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  /// Exchanges the current session for a fresh one (1 request).
  ///
  /// The service answers with a new `MUSIC_U` in `Set-Cookie`. A 200 with no
  /// new cookie is reported rather than being treated as success: nothing was
  /// refreshed, and the caller must not overwrite a working credential with
  /// the one it already had.
  package func refreshSession(
    credential: NeteaseCredential
  ) async throws -> NeteaseCredential {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.refreshRequest(
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.classifyWriteAcknowledgement(data: data, response: httpResponse)
    guard let refreshed = Self.credential(fromSetCookie: httpResponse) else {
      throw NeteaseAuthError.noSessionInResponse
    }
    return refreshed
  }

  package static func logoutRequest(
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    try credentialledEAPIRequest(
      path: logoutEndpoint,
      body: nil,
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
  }

  package static func refreshRequest(
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    try credentialledEAPIRequest(
      path: refreshEndpoint,
      body: nil,
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
  }

  // MARK: - Collected albums and followed artists

  package func collectedAlbums(
    limit: Int = 25,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album> {
    let request = try Self.collectedAlbumsRequest(
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyCollectedAlbums(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit
    )
  }

  package func followedArtists(
    limit: Int = 25,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Artist> {
    let request = try Self.followedArtistsRequest(
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyFollowedArtists(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit
    )
  }

  package func setAlbumCollected(
    _ collected: Bool,
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let request = try Self.albumSubscriptionRequest(
      collected,
      albumID: albumID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package func setArtistFollowed(
    _ followed: Bool,
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let request = try Self.artistSubscriptionRequest(
      followed,
      artistID: artistID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func collectedAlbumsRequest(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let csrf = try csrfJSONValue(credential)
    let json =
      #"{"limit":\#(limit),"offset":\#(offset),"total":true,"csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: albumSublistURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func followedArtistsRequest(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let csrf = try csrfJSONValue(credential)
    let json =
      #"{"limit":\#(limit),"offset":\#(offset),"total":true,"csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: artistSublistURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func albumSubscriptionRequest(
    _ collected: Bool,
    albumID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let csrf = try csrfJSONValue(credential)
    let json = #"{"id":\#(albumID),"csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: collected ? albumSubscribeURL : albumUnsubscribeURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  /// The service wants both the single id and a one-element list; sending only
  /// one of them is accepted and then silently does nothing.
  package static func artistSubscriptionRequest(
    _ followed: Bool,
    artistID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let csrf = try csrfJSONValue(credential)
    let json =
      #"{"artistId":\#(artistID),"artistIds":"[\#(artistID)]","csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: followed ? artistSubscribeURL : artistUnsubscribeURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  /// `hasMore` is absent from some responses, so a full page is taken as
  /// evidence that another may exist. Under-reporting would strand rows the
  /// account has; over-reporting costs one request that returns nothing.
  package static func classifyCollectedAlbums(
    data: Data,
    response: HTTPURLResponse,
    limit: Int
  ) throws -> CatalogPage<Album> {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(AlbumSublistPayload.self, from: data)
    let albums = payload.data.map(\.album)
    return CatalogPage(
      items: albums,
      more: payload.hasMore ?? (albums.count >= limit)
    )
  }

  package static func classifyFollowedArtists(
    data: Data,
    response: HTTPURLResponse,
    limit: Int
  ) throws -> CatalogPage<Artist> {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(ArtistSublistPayload.self, from: data)
    let artists = payload.data.map(\.artist)
    return CatalogPage(
      items: artists,
      more: payload.hasMore ?? (artists.count >= limit)
    )
  }

  // MARK: - Cloud drive

  package func cloudSongs(
    limit: Int = 30,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CloudPage {
    let request = try Self.cloudSongsRequest(
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyCloudSongs(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit
    )
  }

  package func deleteCloudSong(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let request = try Self.cloudDeleteRequest(songID: songID, credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func cloudSongsRequest(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let csrf = try csrfJSONValue(credential)
    let json = #"{"limit":\#(limit),"offset":\#(offset),"csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: cloudURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func cloudDeleteRequest(
    songID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let csrf = try csrfJSONValue(credential)
    let json = #"{"songIds":[\#(songID)],"csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: cloudDeleteURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  package static func classifyCloudSongs(
    data: Data,
    response: HTTPURLResponse,
    limit: Int
  ) throws -> CloudPage {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(CloudPayload.self, from: data)
    let songs = payload.data.map { item in
      CloudSong(
        id: item.songId,
        // The catalogue match is what plays; when there is none the upload's
        // own tags are all that exist, so they stand in rather than leaving a
        // nameless row.
        track: item.simpleSong?.track
          ?? Track(
            id: item.songId,
            name: item.songName ?? item.fileName ?? "Unknown",
            artists: item.artist.map { [ArtistRef(id: nil, name: $0)] } ?? [],
            album: item.album.map { AlbumRef(id: nil, name: $0, artworkURL: nil) }
          ),
        fileName: item.fileName ?? "",
        fileSize: item.fileSize ?? 0
      )
    }
    return CloudPage(
      songs: songs,
      more: payload.hasMore ?? (songs.count >= limit),
      capacity: CloudCapacity(
        usedBytes: payload.size?.value ?? 0,
        totalBytes: payload.maxSize?.value ?? 0
      )
    )
  }

  // MARK: - Playlist privacy

  /// Publishes a private playlist (1 request).
  ///
  /// This one direction is the whole of what is verified. The authority —
  /// `api-enhanced@a7e8d48`, `module/playlist_privacy.js` — sends a fixed
  /// `privacy: 0` to `/api/playlist/update/privacy`, over eapi because
  /// `util/option.js` leaves the crypto empty and `util/config.json` sets
  /// `APP_CONF.encrypt`. Nothing in that repository turns an existing public
  /// playlist private, so MacEase does not offer it: the reverse would be a
  /// contract this client invented. Making a playlist private is done at
  /// creation, through `playlist/create` with `privacy: "10"`.
  package func publishPrivatePlaylist(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.publishPrivatePlaylistRequest(
      playlistID: playlistID,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func publishPrivatePlaylistRequest(
    playlistID: Int64,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    try credentialledEAPIRequest(
      path: playlistPrivacyEndpoint,
      body: #""id":\#(playlistID),"privacy":0"#,
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
  }

  // MARK: - Shared plumbing

  /// The `code == 200` gate every list endpoint shares. An HTTP failure has no
  /// service code to read, so it is classified first.
  static func requireSuccess(
    data: Data,
    response: HTTPURLResponse
  ) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }
    let code = try JSONDecoder().decode(ServiceCode.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
  }

  /// The sign-in endpoints run before there is a credential, so the eapi
  /// header carries the platform identity and nothing else. No anonymous
  /// device token is invented to fill the gap.
  private static func anonymousEAPIRequest(
    path: String,
    body: String
  ) throws -> URLRequest {
    let timestamp = Date().timeIntervalSince1970
    let fields: [(String, String)] = [
      ("osver", osVersion),
      ("os", "osx"),
      ("appver", "0.1"),
      ("buildver", String(Int(timestamp))),
      ("channel", "github"),
      ("requestId", requestID(timestamp: timestamp)),
    ]
    return try eapiFormRequest(
      path: path,
      json: #"{\#(body),"e_r":false,"header":\#(try eapiHeaderJSON(fields))}"#,
      headerFields: fields
    )
  }

  private static func credentialledEAPIRequest(
    path: String,
    body: String?,
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
    let prefix = body.map { $0 + "," } ?? ""
    return try eapiFormRequest(
      path: path,
      json: #"{\#(prefix)"e_r":false,"header":\#(header)}"#,
      headerFields: fields
    )
  }

  static func eapiFormRequest(
    path: String,
    json: String,
    headerFields: [(String, String)],
    url explicitURL: URL? = nil
  ) throws -> URLRequest {
    guard let url = explicitURL ?? eapiURL(path) else {
      throw NeteaseAuthError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([
      ("params", try NeteaseCrypto.eapi(path: path, json: json))
    ])
    request.httpShouldHandleCookies = false
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("MacEasePhase0/0.1 (macOS 15)", forHTTPHeaderField: "User-Agent")
    request.setValue(
      headerFields.map { "\($0.0)=\($0.1)" }.joined(separator: "; "),
      forHTTPHeaderField: "Cookie"
    )
    return request
  }

  private static func anonymousWeAPIRequest(
    url: URL,
    json: String,
    secretKey: String?
  ) throws -> URLRequest {
    let parameters = try weapiParameters(json: json, secretKey: secretKey)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([
      ("params", parameters.params),
      ("encSecKey", parameters.encSecKey),
    ])
    request.httpShouldHandleCookies = false
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
    request.setValue(platformCookies(), forHTTPHeaderField: "Cookie")
    return request
  }

  /// The session URL session is built with cookie storage switched off, so a
  /// sign-in response has to be read out of `Set-Cookie` by hand. That is the
  /// point: nothing is kept implicitly, and only the two cookie names MacEase
  /// recognises survive.
  static func credential(
    fromSetCookie response: HTTPURLResponse
  ) -> NeteaseCredential? {
    guard let url = response.url else { return nil }
    let cookies = HTTPCookie.cookies(
      withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:],
      for: url
    )
    var musicU: NeteaseCookie?
    var csrf: NeteaseCookie?
    for cookie in cookies {
      guard let name = NeteaseCookie.Name(rawValue: cookie.name) else { continue }
      guard let approved = NeteaseCookie(name: name, value: cookie.value) else {
        continue
      }
      switch name {
      case .musicU: musicU = approved
      case .csrf: csrf = approved
      }
    }
    guard let musicU else { return nil }
    return NeteaseCredential(musicU: musicU, csrf: csrf)
  }

  /// Phone numbers and codes go into the request body as raw digits, so they
  /// are checked to be digits. This is the same rule the cookie values are
  /// held to: nothing the user types reaches a payload unvalidated.
  static func isPlausiblePhoneNumber(_ value: String) -> Bool {
    (4...15).contains(value.count) && value.allSatisfy(\.isASCIIDigit)
  }

  static func isPlausibleCountryCode(_ value: String) -> Bool {
    (1...4).contains(value.count) && value.allSatisfy(\.isASCIIDigit)
  }

  static func isPlausibleVerificationCode(_ value: String) -> Bool {
    (4...8).contains(value.count) && value.allSatisfy(\.isASCIIDigit)
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

private struct ServiceCode: Decodable {
  let code: Int
}

private struct QRKeyPayload: Decodable {
  let code: Int
  let unikey: String?

  private enum CodingKeys: String, CodingKey {
    case code
    case unikey
    case data
  }

  private struct Inner: Decodable {
    let unikey: String?
  }

  /// The module wraps the service body in `data` before returning it, but the
  /// service itself answers at the top level. Both spellings are read so the
  /// key is found either way.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(Int.self, forKey: .code)
    unikey =
      try container.decodeIfPresent(String.self, forKey: .unikey)
      ?? container.decodeIfPresent(Inner.self, forKey: .data)?.unikey
  }
}

private struct AlbumSublistPayload: Decodable {
  let data: [AlbumRowPayload]
  let hasMore: Bool?
}

private struct ArtistSublistPayload: Decodable {
  let data: [ArtistRowPayload]
  let hasMore: Bool?
}

private struct CloudPayload: Decodable {
  let data: [Item]
  let hasMore: Bool?
  /// Reported as a decimal string on this endpoint and as a number on others.
  let size: LenientInt64?
  let maxSize: LenientInt64?

  struct Item: Decodable {
    let songId: Int64
    let fileName: String?
    let fileSize: Int64?
    let songName: String?
    let artist: String?
    let album: String?
    let simpleSong: SongRowPayload?
  }
}

/// An integer NetEase writes either as a JSON number or as a decimal string.
/// Anything else is not a size, and is read as absent rather than as zero.
private struct LenientInt64: Decodable {
  let value: Int64?

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Int64.self) {
      value = number
    } else if let text = try? container.decode(String.self) {
      value = Int64(text)
    } else {
      value = nil
    }
  }
}
