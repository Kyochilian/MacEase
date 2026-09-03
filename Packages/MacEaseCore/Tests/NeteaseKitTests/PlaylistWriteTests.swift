import Foundation
import Testing

@testable import NeteaseKit

private let writeCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

private let okResponse = HTTPURLResponse(
  url: URL(string: "https://music.163.com")!,
  statusCode: 200,
  httpVersion: nil,
  headerFields: nil
)!

private func expectWeAPIWriteBody(
  _ request: URLRequest,
  json: String,
  secretKey: String = "0123456789abcdef"
) throws {
  let parameters = try NeteaseCrypto.weapi(json: json, secretKey: secretKey)
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

private let eapiHeader =
  #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
  + #""__csrf":"csrf-test","channel":"github","#
  + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#

@Test func createPlaylistRequestUsesTheLockedContract() throws {
  let request = try NeteaseSession.createPlaylistRequest(
    name: "Test List",
    isPrivate: false,
    credential: writeCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/playlist/create")
  try expectWeAPIWriteBody(
    request,
    json:
      #"{"name":"Test List","privacy":"0","type":"NORMAL","csrf_token":"csrf-test"}"#
  )
  // Writes carry MacEase's own platform identity, never a fabricated device ID.
  let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
  #expect(cookie.contains("os=osx"))
  #expect(!cookie.contains("deviceId"))
}

/// The one verified way to get a private playlist: `privacy` is `"10"` at
/// creation, a string, exactly as `module/playlist_create.js` sends it in
/// `api-enhanced@a7e8d48`. Everything else about the request is unchanged.
@Test func creatingAPrivatePlaylistSendsPrivacyTen() throws {
  let request = try NeteaseSession.createPlaylistRequest(
    name: "Test List",
    isPrivate: true,
    credential: writeCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/playlist/create")
  try expectWeAPIWriteBody(
    request,
    json:
      #"{"name":"Test List","privacy":"10","type":"NORMAL","csrf_token":"csrf-test"}"#
  )
}

@Test func createPlaylistEscapesNamesThatWouldBreakJSON() throws {
  let request = try NeteaseSession.createPlaylistRequest(
    name: #"quote " and \ backslash"#,
    isPrivate: false,
    credential: writeCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPIWriteBody(
    request,
    json:
      #"{"name":"quote \" and \\ backslash","privacy":"0","type":"NORMAL","csrf_token":"csrf-test"}"#
  )
}

@Test func deletePlaylistRequestWrapsTheIDList() throws {
  let request = try NeteaseSession.deletePlaylistRequest(
    playlistID: 24_381_616,
    credential: writeCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/playlist/remove")
  try expectWeAPIWriteBody(
    request,
    json: #"{"ids":"[24381616]","csrf_token":"csrf-test"}"#
  )
}

@Test func editPlaylistTracksSendsOpAndStringifiedIDs() throws {
  let add = try NeteaseSession.editPlaylistTracksRequest(
    .add,
    playlistID: 24_381_616,
    trackIDs: [33_894_312, 347_230],
    credential: writeCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let addJSON =
    #"{"op":"add","pid":24381616,"trackIds":"[33894312,347230]","#
    + #""imme":"true","e_r":false,"header":\#(eapiHeader)}"#

  #expect(
    add.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/playlist/manipulate/tracks"
  )
  let addParams = try NeteaseCrypto.eapi(
    path: "/api/playlist/manipulate/tracks",
    json: addJSON
  )
  #expect(
    String(decoding: add.httpBody!, as: UTF8.self) == "params=\(addParams)"
  )

  let remove = try NeteaseSession.editPlaylistTracksRequest(
    .del,
    playlistID: 24_381_616,
    trackIDs: [33_894_312],
    credential: writeCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  #expect(remove.httpBody != add.httpBody)

  #expect(throws: (any Error).self) {
    try NeteaseSession.editPlaylistTracksRequest(
      .add,
      playlistID: 1,
      trackIDs: [],
      credential: writeCredential,
      osVersion: "15.5",
      buildVersion: "1",
      requestID: "1_0001"
    )
  }
}

@Test func renamePlaylistSendsOnlyTheNameSubRequest() throws {
  let request = try NeteaseSession.renamePlaylistRequest(
    playlistID: 24_381_616,
    name: "Renamed",
    credential: writeCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )

  // Body equality is the real guard: the reference implementation also sends
  // desc and tags defaulted to empty, which wipes them. If MacEase ever added
  // those sub-requests, this expected body would no longer match.
  let inner = #"{"id":24381616,"name":"Renamed"}"#
  let encodedInner = String(decoding: try JSONEncoder().encode(inner), as: UTF8.self)
  let json =
    #"{"/api/playlist/update/name":\#(encodedInner),"e_r":false,"header":\#(eapiHeader)}"#

  #expect(request.url?.absoluteString == "https://interfacepc.music.163.com/eapi/batch")
  let batchParams = try NeteaseCrypto.eapi(path: "/api/batch", json: json)
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self) == "params=\(batchParams)"
  )
}

@Test func subscribeUsesDistinctPaths() throws {
  let subscribe = try NeteaseSession.subscribePlaylistRequest(
    true,
    playlistID: 24_381_616,
    credential: writeCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let json = #"{"id":24381616,"e_r":false,"header":\#(eapiHeader)}"#

  #expect(
    subscribe.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/playlist/subscribe"
  )
  let subscribeParams = try NeteaseCrypto.eapi(
    path: "/api/playlist/subscribe",
    json: json
  )
  #expect(
    String(decoding: subscribe.httpBody!, as: UTF8.self)
      == "params=\(subscribeParams)"
  )

  let unsubscribe = try NeteaseSession.subscribePlaylistRequest(
    false,
    playlistID: 24_381_616,
    credential: writeCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  #expect(
    unsubscribe.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/playlist/unsubscribe"
  )
}

@Test func writeAcknowledgementAcceptsOnlyCode200() throws {
  try NeteaseSession.requireSuccess(
    data: Data(#"{"code":200}"#.utf8),
    response: okResponse
  )
  // 512 is the reference implementation's retry trigger; MacEase reports it.
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 512)) {
    try NeteaseSession.requireSuccess(
      data: Data(#"{"code":512}"#.utf8),
      response: okResponse
    )
  }
}
