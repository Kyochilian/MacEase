import Foundation
import Testing

@testable import NeteaseKit

private let accountCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

private let okResponse = HTTPURLResponse(
  url: URL(string: "https://music.163.com")!,
  statusCode: 200,
  httpVersion: nil,
  headerFields: nil
)!

private func response(setCookie: String) -> HTTPURLResponse {
  HTTPURLResponse(
    url: URL(string: "https://music.163.com/eapi/login/qrcode/client/login")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: ["Set-Cookie": setCookie]
  )!
}

// MARK: - QR sign-in

@Test func qrKeyRequestUsesTheAnonymousEAPIEnvelope() throws {
  let request = try NeteaseSession.qrKeyRequest()

  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/login/qrcode/unikey"
  )
  #expect(request.httpMethod == "POST")
  #expect(request.httpShouldHandleCookies == false)
  // No credential exists yet, so no MUSIC_U may be claimed and no anonymous
  // device token is invented to stand in for one.
  let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
  #expect(!cookie.contains("MUSIC_U"))
  #expect(!cookie.contains("MUSIC_A"))
  #expect(cookie.contains("os=osx"))
  #expect(cookie.contains("channel=github"))
}

@Test func qrCheckRequestCarriesTheKeyAndTheClientType() throws {
  let request = try NeteaseSession.qrCheckRequest(key: "abc-123")

  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/login/qrcode/client/login"
  )
  let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  #expect(body.hasPrefix("params="))
}

@Test func qrKeyDecodesEitherResponseShape() throws {
  let flat = try NeteaseSession.classifyQRKey(
    data: Data(#"{"code":200,"unikey":"K1"}"#.utf8),
    response: okResponse
  )
  let wrapped = try NeteaseSession.classifyQRKey(
    data: Data(#"{"code":200,"data":{"unikey":"K1"}}"#.utf8),
    response: okResponse
  )

  #expect(flat == "K1")
  #expect(wrapped == "K1")
}

@Test func qrKeyRejectsAnEmptyKey() throws {
  #expect(throws: NeteaseAuthError.invalidResponse) {
    try NeteaseSession.classifyQRKey(
      data: Data(#"{"code":200,"unikey":""}"#.utf8),
      response: okResponse
    )
  }
}

/// 800 to 803 are this endpoint's ordinary answers. Reporting an unscanned
/// code as a service error would put a failure in front of a user who is
/// simply still reaching for their phone.
@Test func qrPollTreatsTheLifecycleCodesAsStatusRatherThanFailure() throws {
  #expect(
    try NeteaseSession.classifyQRPoll(
      data: Data(#"{"code":800}"#.utf8),
      response: okResponse
    ) == .expired
  )
  #expect(
    try NeteaseSession.classifyQRPoll(
      data: Data(#"{"code":801}"#.utf8),
      response: okResponse
    ) == .waiting
  )
  #expect(
    try NeteaseSession.classifyQRPoll(
      data: Data(#"{"code":802}"#.utf8),
      response: okResponse
    ) == .scanned
  )
}

@Test func qrPollExtractsTheSessionFromSetCookie() throws {
  let status = try NeteaseSession.classifyQRPoll(
    data: Data(#"{"code":803}"#.utf8),
    response: response(
      setCookie: "MUSIC_U=granted-token; Path=/; HttpOnly, __csrf=granted-csrf; Path=/"
    )
  )

  guard case .authorised(let credential) = status else {
    Issue.record("expected an authorised status, got \(status)")
    return
  }
  #expect(credential.musicU.value == "granted-token")
  #expect(credential.csrf?.value == "granted-csrf")
}

/// A confirmed scan with no cookie is not a sign-in. Reporting it as one would
/// leave the app believing it had a session it cannot use.
@Test func qrPollRefusesAConfirmationWithoutACookie() throws {
  #expect(throws: NeteaseAuthError.noSessionInResponse) {
    try NeteaseSession.classifyQRPoll(
      data: Data(#"{"code":803}"#.utf8),
      response: response(setCookie: "NMTID=irrelevant; Path=/")
    )
  }
}

@Test func qrPollStillReportsGenuineServiceErrors() throws {
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 400)) {
    try NeteaseSession.classifyQRPoll(
      data: Data(#"{"code":400}"#.utf8),
      response: okResponse
    )
  }
}

// MARK: - SMS sign-in

@Test func captchaRequestMatchesTheLockedContract() throws {
  let request = try NeteaseSession.captchaRequest(
    phone: "13800138000",
    countryCode: "86",
    secretKey: "0123456789abcdef"
  )
  let parameters = try NeteaseCrypto.weapi(
    json:
      #"{"ctcode":"86","secrete":"music_middleuser_pclogin","#
      + #""cellphone":"13800138000","csrf_token":""}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(
    request.url?.absoluteString == "https://music.163.com/weapi/sms/captcha/sent"
  )
  #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.163.com/")
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", parameters.params),
          ("encSecKey", parameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
}

/// The phone number and the code go into the payload as raw digits, so an
/// entry that is not digits must be refused before it is interpolated rather
/// than after the service rejects it.
@Test func smsRequestsRefuseInputThatIsNotDigits() throws {
  #expect(throws: NeteaseAuthError.invalidPhoneNumber) {
    try NeteaseSession.captchaRequest(phone: #"1","x":"y"#, countryCode: "86")
  }
  #expect(throws: NeteaseAuthError.invalidPhoneNumber) {
    try NeteaseSession.captchaRequest(phone: "138", countryCode: "8\"6")
  }
  #expect(throws: NeteaseAuthError.invalidPhoneNumber) {
    try NeteaseSession.cellphoneLoginRequest(
      phone: "13800138000",
      code: "12\"34",
      countryCode: "86"
    )
  }
}

@Test func cellphoneLoginSendsOnlyTheCodeForm() throws {
  let request = try NeteaseSession.cellphoneLoginRequest(
    phone: "13800138000",
    code: "123456",
    countryCode: "86",
    secretKey: "0123456789abcdef"
  )
  let json =
    #"{"type":"1","https":"true","phone":"13800138000","countrycode":"86","#
    + #""captcha":"123456","remember":"true","secureCaptcha":"","csrf_token":""}"#
  let parameters = try NeteaseCrypto.weapi(
    json: json,
    secretKey: "0123456789abcdef"
  )

  #expect(
    request.url?.absoluteString == "https://music.163.com/weapi/w/login/cellphone"
  )
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", parameters.params),
          ("encSecKey", parameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
  // A password never leaves this app, so the field it would occupy is absent.
  #expect(!json.contains("password"))
}

@Test func cellphoneLoginRequiresASessionCookieToSucceed() throws {
  #expect(throws: NeteaseAuthError.noSessionInResponse) {
    try NeteaseSession.classifyCellphoneLogin(
      data: Data(#"{"code":200}"#.utf8),
      response: okResponse
    )
  }

  let credential = try NeteaseSession.classifyCellphoneLogin(
    data: Data(#"{"code":200}"#.utf8),
    response: response(setCookie: "MUSIC_U=phone-token; Path=/; HttpOnly")
  )
  #expect(credential.musicU.value == "phone-token")
  #expect(credential.csrf == nil)
}

/// A cookie value that could break out of the `Cookie` header must be dropped
/// at the boundary, exactly as the manual-import path drops it.
@Test func setCookieExtractionRefusesAnUnusableValue() throws {
  #expect(throws: NeteaseAuthError.noSessionInResponse) {
    try NeteaseSession.classifyCellphoneLogin(
      data: Data(#"{"code":200}"#.utf8),
      response: response(setCookie: "MUSIC_U=; Path=/")
    )
  }
}

// MARK: - Sign-out and refresh

@Test func logoutAndRefreshUseTheCredentialledEAPIEnvelope() throws {
  let logout = try NeteaseSession.logoutRequest(
    credential: accountCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let refresh = try NeteaseSession.refreshRequest(
    credential: accountCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let header =
    #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
    + #""__csrf":"csrf-test","channel":"github","#
    + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#

  #expect(
    logout.url?.absoluteString == "https://interfacepc.music.163.com/eapi/logout"
  )
  #expect(
    refresh.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/login/token/refresh"
  )
  let logoutParams = try NeteaseCrypto.eapi(
    path: "/api/logout",
    json: #"{"e_r":false,"header":\#(header)}"#
  )
  #expect(
    String(decoding: logout.httpBody!, as: UTF8.self) == "params=\(logoutParams)"
  )
}

// MARK: - Collected albums and followed artists

@Test func collectedAlbumsRequestAndDecode() throws {
  let request = try NeteaseSession.collectedAlbumsRequest(
    limit: 25,
    offset: 50,
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  #expect(
    request.url?.absoluteString == "https://music.163.com/weapi/album/sublist"
  )

  let page = try NeteaseSession.classifyCollectedAlbums(
    data: Data((
      #"{"code":200,"hasMore":false,"data":[{"id":7,"name":"A","size":11,"#
        + #""picUrl":"https://p3.music.126.net/a.jpg","#
        + #""artists":[{"id":3,"name":"X"},{"id":4,"name":"Y"}]}]}"#
      ).utf8),
    response: okResponse,
    limit: 25
  )

  #expect(page.more == false)
  #expect(
    page.items == [
      Album(
        id: 7,
        name: "A",
        artists: [ArtistRef(id: 3, name: "X"), ArtistRef(id: 4, name: "Y")],
        artworkURL: URL(string: "https://p3.music.126.net/a.jpg"),
        trackCount: 11
      )
    ]
  )
}

/// The list returns a single `artist` for a normal release and `artists` for a
/// compilation. Reading only one of them empties the other kind of row.
@Test func collectedAlbumsReadBothArtistSpellings() throws {
  let page = try NeteaseSession.classifyCollectedAlbums(
    data: Data(
      #"{"code":200,"data":[{"id":7,"name":"A","artist":{"id":3,"name":"X"}}]}"#.utf8
    ),
    response: okResponse,
    limit: 25
  )

  #expect(page.items.first?.artists == [ArtistRef(id: 3, name: "X")])
  #expect(page.items.first?.artistDisplayName == "X")
}

/// Without `hasMore`, a page that came back full is the only evidence that
/// more may exist. Assuming otherwise would strand the rest of the collection.
@Test func collectionPagesInferMoreFromAFullPage() throws {
  let full = try NeteaseSession.classifyFollowedArtists(
    data: Data(
      #"{"code":200,"data":[{"id":1,"name":"A"},{"id":2,"name":"B"}]}"#.utf8
    ),
    response: okResponse,
    limit: 2
  )
  let partial = try NeteaseSession.classifyFollowedArtists(
    data: Data(#"{"code":200,"data":[{"id":1,"name":"A"}]}"#.utf8),
    response: okResponse,
    limit: 2
  )

  #expect(full.more)
  #expect(partial.more == false)
}

@Test func followedArtistsFallBackToTheSquareImage() throws {
  let page = try NeteaseSession.classifyFollowedArtists(
    data: Data((
      #"{"code":200,"data":[{"id":1,"name":"A","albumSize":3,"musicSize":40,"#
        + #""img1v1Url":"https://p4.music.126.net/square.jpg"}]}"#
      ).utf8),
    response: okResponse,
    limit: 25
  )

  #expect(
    page.items == [
      Artist(
        id: 1,
        name: "A",
        artworkURL: URL(string: "https://p4.music.126.net/square.jpg"),
        albumCount: 3,
        songCount: 40
      )
    ]
  )
}

@Test func artistFollowSendsBothIdentifierFields() throws {
  let request = try NeteaseSession.artistSubscriptionRequest(
    true,
    artistID: 6452,
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  let parameters = try NeteaseCrypto.weapi(
    json: #"{"artistId":6452,"artistIds":"[6452]","csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/artist/sub")
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", parameters.params),
          ("encSecKey", parameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )

  let unfollow = try NeteaseSession.artistSubscriptionRequest(
    false,
    artistID: 6452,
    credential: accountCredential
  )
  #expect(unfollow.url?.absoluteString == "https://music.163.com/weapi/artist/unsub")
}

@Test func albumCollectionUsesTheSubAndUnsubPaths() throws {
  #expect(
    try NeteaseSession.albumSubscriptionRequest(
      true,
      albumID: 9,
      credential: accountCredential
    ).url?.absoluteString == "https://music.163.com/weapi/album/sub"
  )
  #expect(
    try NeteaseSession.albumSubscriptionRequest(
      false,
      albumID: 9,
      credential: accountCredential
    ).url?.absoluteString == "https://music.163.com/weapi/album/unsub"
  )
}

// MARK: - Cloud drive

@Test func cloudSongsDecodeTheMatchedTrackAndCapacity() throws {
  let page = try NeteaseSession.classifyCloudSongs(
    data: Data((
      #"{"code":200,"hasMore":false,"size":"1048576","maxSize":"6442450944","#
        + #""data":[{"songId":501,"fileName":"a.flac","fileSize":40000000,"#
        + #""songName":"Tagged","artist":"Tag","album":"TagAlbum","#
        + #""simpleSong":{"id":501,"name":"Matched","dt":210000,"#
        + #""ar":[{"id":8,"name":"Real"}],"al":{"id":9,"name":"RealAlbum"}}}]}"#
      ).utf8),
    response: okResponse,
    limit: 30
  )

  #expect(page.capacity == CloudCapacity(usedBytes: 1_048_576, totalBytes: 6_442_450_944))
  #expect(page.more == false)
  // The catalogue match is what plays, so it wins over the upload's own tags.
  #expect(page.songs.first?.track.name == "Matched")
  #expect(page.songs.first?.track.artists == [ArtistRef(id: 8, name: "Real")])
  #expect(page.songs.first?.fileName == "a.flac")
  #expect(page.songs.first?.fileSize == 40_000_000)
}

/// An upload NetEase never matched has no catalogue entry, so its own tags are
/// all that exist. A nameless row would be worse than the tags.
@Test func cloudSongsFallBackToTheUploadTags() throws {
  let page = try NeteaseSession.classifyCloudSongs(
    data: Data((
      #"{"code":200,"size":0,"maxSize":0,"data":[{"songId":77,"#
        + #""fileName":"b.mp3","fileSize":1,"songName":"Local","artist":"Me","#
        + #""album":"Mine"}]}"#
      ).utf8),
    response: okResponse,
    limit: 30
  )

  #expect(page.songs.first?.track.name == "Local")
  #expect(page.songs.first?.track.artists == [ArtistRef(id: nil, name: "Me")])
  #expect(page.songs.first?.track.album?.name == "Mine")
  // Neither is navigable: the upload is not in the catalogue.
  #expect(page.songs.first?.track.album?.id == nil)
}

/// Capacity arrives as a decimal string on this endpoint and as a number on
/// others. Both are the same size.
@Test func cloudCapacityReadsBothNumberAndStringForms() throws {
  let asNumbers = try NeteaseSession.classifyCloudSongs(
    data: Data(#"{"code":200,"size":12,"maxSize":34,"data":[]}"#.utf8),
    response: okResponse,
    limit: 30
  )
  let asStrings = try NeteaseSession.classifyCloudSongs(
    data: Data(#"{"code":200,"size":"12","maxSize":"34","data":[]}"#.utf8),
    response: okResponse,
    limit: 30
  )

  #expect(asNumbers.capacity == asStrings.capacity)
  #expect(asNumbers.capacity == CloudCapacity(usedBytes: 12, totalBytes: 34))
}

@Test func cloudDeleteNamesTheSongInAList() throws {
  let request = try NeteaseSession.cloudDeleteRequest(
    songID: 501,
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  let parameters = try NeteaseCrypto.weapi(
    json: #"{"songIds":[501],"csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/cloud/del")
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", parameters.params),
          ("encSecKey", parameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
}

// MARK: - Playlist privacy

@Test func playlistPrivacySendsTheServiceValues() throws {
  let makePrivate = try NeteaseSession.playlistPrivacyRequest(
    true,
    playlistID: 24_381_616,
    credential: accountCredential,
    secretKey: "0123456789abcdef",
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let publish = try NeteaseSession.playlistPrivacyRequest(
    false,
    playlistID: 24_381_616,
    credential: accountCredential,
    secretKey: "0123456789abcdef",
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )

  #expect(
    makePrivate.url?.absoluteString
      == "https://music.163.com/weapi/playlist/update/privacy"
  )
  let privateParameters = try NeteaseCrypto.weapi(
    json: #"{"id":24381616,"privacy":10,"csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )
  let publicParameters = try NeteaseCrypto.weapi(
    json: #"{"id":24381616,"privacy":0,"csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )
  #expect(
    String(decoding: makePrivate.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", privateParameters.params),
          ("encSecKey", privateParameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
  #expect(
    String(decoding: publish.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", publicParameters.params),
          ("encSecKey", publicParameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
}
