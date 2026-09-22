import Foundation
import Testing

@testable import NeteaseKit

/// Explicit, read-only acceptance probe. Uses the product transport and decoder;
/// the two alternative routes isolate the domain/encryption differences seen in Kumone.
/// Never prints credentials, response bodies or signed media URLs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACEASE_NETWORK_TIMING"] == "1"))
func realPlaylistRouteTimings() async throws {
  // Authentication is optional and explicitly enabled; ordinary route measurements
  // use no account, so a Keychain prompt cannot be confused with network latency.
  let credential: NeteaseCredential?
  if ProcessInfo.processInfo.environment["MACEASE_NETWORK_AUTHENTICATED"] == "1" {
    timingOutput("credential_read=started")
    guard let stored = try await CredentialVault().load() else {
      Issue.record("No stored MacEase session")
      return
    }
    credential = stored
  } else {
    credential = nil
  }
  timingOutput("credential_read=finished authenticated=\(credential != nil)")

  let playlistID: Int64 = 19_723_756
  let sessions = (0..<3).map { _ in
    NeteaseSession(configuration: .ephemeral, diagnostics: { timingOutput($0.line) })
  }
  // Alternate the first route so one variant does not always get the cold connection.
  for round in 0..<3 {
    for route in (0..<3).map({ ($0 + round) % 3 }) {
      timingOutput("sample round=\(round) route=\(route)")
      do {
        let (data, response) = try await sessions[route].send(credential: credential) { nmtid in
          if route == 1 {
            let json =
              #"{"id":\#(playlistID),"n":100000,"s":8,"csrf_token":\#(try credential.map(NeteaseSession.csrfJSONValue) ?? "\"\"")}"#
            let parameters = try NeteaseSession.weapiParameters(json: json, secretKey: nil)
            var request = URLRequest(
              url: URL(string: "https://music.163.com/weapi/v6/playlist/detail")!)
            request.httpMethod = "POST"
            request.httpBody = FormURLEncoder.encode([
              ("params", parameters.params), ("encSecKey", parameters.encSecKey),
            ])
            request.setValue(
              "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            if let credential {
              request.setValue(
                NeteaseSession.cookieHeader(credential), forHTTPHeaderField: "Cookie")
            }
            return request

          }
          var request: URLRequest
          if let credential {
            request = try NeteaseSession.playlistDetailRequest(
              playlistID: playlistID, credential: credential, osVersion: NeteaseSession.osVersion,
              buildVersion: String(Int(Date().timeIntervalSince1970)),
              requestID: NeteaseSession.requestID(timestamp: Date().timeIntervalSince1970),
              nmtid: nmtid)
          } else {
            var header = [
              ("os", "osx"), ("osver", NeteaseSession.osVersion), ("appver", "0.1"),
              ("channel", "github"),
            ]
            if let nmtid { header.append(("NMTID", nmtid)) }
            let json =
              #"{"id":\#(playlistID),"n":100000,"s":8,"e_r":false,"header":\#(try NeteaseSession.eapiHeaderJSON(header))}"#
            request = try NeteaseSession.eapiFormRequest(
              path: "/api/v6/playlist/detail", json: json, headerFields: header)
          }
          if route == 2 {
            request.url = URL(string: "https://interface.music.163.com/eapi/v6/playlist/detail")!
          }
          return request
        }
        let detail = try NeteaseSession.classifyPlaylistDetail(
          data: data, response: NeteaseSession.requireHTTPResponse(response), playlistID: playlistID
        )
        timingOutput(
          "sample_result round=\(round) route=\(route) business=success ids=\(detail.trackIDs.count) embedded_tracks=\(detail.tracks.count)"
        )
      } catch let error as NeteaseServiceError {
        timingOutput(
          "sample_result round=\(round) route=\(route) source=\(error.source.rawValue) code=\(error.statusCode)"
        )
      } catch {
        timingOutput("sample_result round=\(round) route=\(route) error=\((error as NSError).code)")
      }
    }
  }
}

@Test func playlistResponseReusesEmbeddedRowsAndTopLevelPrivileges() throws {
  let data = Data(
    #"{"code":200,"playlist":{"id":5,"name":"test","trackIds":[{"id":1},{"id":2}],"tracks":[{"id":2,"name":"second"},{"id":1,"name":"first"},{"id":9,"name":"unrelated"}]},"privileges":[{"id":1,"fee":1,"st":-200}]}"#
      .utf8)
  let response = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com/eapi/v6/playlist/detail")!, statusCode: 200,
    httpVersion: nil, headerFields: nil)!
  let detail = try NeteaseSession.classifyPlaylistDetail(
    data: data, response: response, playlistID: 5)
  #expect(detail.tracks.map(\.id) == [1, 2])
  #expect(detail.tracks.first?.privilege != nil)
}

private func timingOutput(_ line: String) {
  FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
