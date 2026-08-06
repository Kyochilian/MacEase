import Foundation
import Testing

@testable import NeteaseKit

@Test func lyricsProbeRequestGoldenVector() {
  let request = NeteaseSession.lyricsProbeRequest(songID: 347_230)

  #expect(request.url?.absoluteString == "https://interfacepc.music.163.com/eapi/song/lyric/v1")
  #expect(request.httpMethod == "POST")
  #expect(
    request.value(forHTTPHeaderField: "Content-Type")
      == "application/x-www-form-urlencoded"
  )
  #expect(request.value(forHTTPHeaderField: "User-Agent") == "MacEasePhase0/0.1 (macOS 15)")
  #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
  #expect(!request.httpShouldHandleCookies)
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == "params=04AE33D34A93FE3EC22DA8FA305D290AB337D0FE5F36D211DE0D338CC6AA89D01717D08618A3071995EA6F04B47A1C8CD461DFF90077763EC1AEFEEA70B344C419ABCE961F17B6B8EC72B6A226725280E97469E44EE0EE9B82E7B6CB0ADD23232E0EAC4A2DE3CBFFBC95F6348044FFB17F333D604488DEEC6FFC731387492271A4BEC36F6FA6E008C121DCE201F8C71F03BBE2089BE546B70A3B68C2344E73ED5E50317E41FD053E88CCA6E620CEDEA7764B3D107F6BDB666ABE83D153B9F5F7"
  )
}

@Test func lyricsProbeClassifiesResponses() {
  let url = URL(string: "https://interfacepc.music.163.com/eapi/song/lyric/v1")!
  let success = HTTPURLResponse(
    url: url,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  #expect(
    NeteaseSession.classifyLyricsProbe(
      data: Data(#"{"code":200,"lrc":{"lyric":"redacted"}}"#.utf8),
      response: success
    ) == LyricsProbeOutcome(status: .content, setsCookie: false)
  )
  #expect(
    NeteaseSession.classifyLyricsProbe(
      data: Data(#"{"code":200,"nolyric":true}"#.utf8),
      response: success
    ) == LyricsProbeOutcome(status: .noLyrics, setsCookie: false)
  )
  #expect(
    NeteaseSession.classifyLyricsProbe(
      data: Data(#"{"code":301}"#.utf8),
      response: success
    ) == LyricsProbeOutcome(status: .service(301), setsCookie: false)
  )
  #expect(
    NeteaseSession.classifyLyricsProbe(
      data: Data("invalid".utf8),
      response: success
    ) == LyricsProbeOutcome(status: .invalidResponse, setsCookie: false)
  )
  let unavailable = HTTPURLResponse(
    url: url,
    statusCode: 503,
    httpVersion: nil,
    headerFields: ["Set-Cookie": "discarded=1"]
  )!
  #expect(
    NeteaseSession.classifyLyricsProbe(data: Data(), response: unavailable)
      == LyricsProbeOutcome(status: .http(503), setsCookie: true)
  )
}
