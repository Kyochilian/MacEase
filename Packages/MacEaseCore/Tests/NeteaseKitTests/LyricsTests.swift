import Foundation
import Testing

@testable import NeteaseKit

private let lyricsCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

private let okResponse = HTTPURLResponse(
  url: URL(string: "https://interfacepc.music.163.com")!,
  statusCode: 200,
  httpVersion: nil,
  headerFields: nil
)!

@Test func lyricsRequestUsesTheLockedEAPIContract() throws {
  let request = try NeteaseSession.lyricsRequest(
    songID: 347_230,
    credential: lyricsCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let header =
    #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
    + #""__csrf":"csrf-test","channel":"github","#
    + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#
  let json =
    #"{"id":"347230","cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"#
    + #""ytv":0,"yrv":0,"e_r":false,"header":\#(header)}"#

  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/song/lyric/v1"
  )
  #expect(request.httpMethod == "POST")
  #expect(request.httpShouldHandleCookies == false)
  // Unlike the Gate A probe, the product request carries the account, which is
  // what makes the account's own translation entitlement apply.
  #expect(
    request.value(forHTTPHeaderField: "Cookie")
      == "osver=15.5; os=osx; appver=0.1; buildver=1722945678; __csrf=csrf-test;"
      + " channel=github; requestId=1722945678123_0042; MUSIC_U=music-u-test"
  )
  let params = try NeteaseCrypto.eapi(path: "/api/song/lyric/v1", json: json)
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self) == "params=\(params)"
  )
}

@Test func lyricsMergeTranslationAndRomanisationOntoSharedTimestamps() throws {
  let lyrics = try NeteaseSession.classifyLyrics(
    data: Data((
      #"{"code":200,"lrc":{"lyric":"[00:01.00]One\n[00:12.34]Two\n"},"#
        + #""tlyric":{"lyric":"[00:12.340]二\n"},"#
        + #""romalrc":{"lyric":"[00:12.34]Er\n"}}"#
      ).utf8),
    response: okResponse
  )

  #expect(
    lyrics == .lines([
      LyricLine(timeSeconds: 1, text: "One"),
      LyricLine(timeSeconds: 12.34, text: "Two", translation: "二", romanisation: "Er"),
    ])
  )
}

/// The two spellings of one centisecond — `.34` and `.340` — must key to the
/// same line, or every translation NetEase writes at millisecond precision
/// would silently vanish.
@Test func lyricsMatchTimestampsAcrossPrecisionSpellings() {
  let lyrics = LyricsParser.parse(
    lrc: "[01:05.5]A\n[02:00]B",
    translation: "[01:05.50]甲\n[02:00.000]乙",
    romanisation: nil
  )

  #expect(lyrics.lines.map(\.translation) == ["甲", "乙"])
  #expect(lyrics.lines.map(\.timeSeconds) == [65.5, 120])
}

/// A positive `[offset:]` means the words should arrive earlier, so it is
/// subtracted. Getting the sign wrong puts every line on the wrong side of the
/// music by twice the offset.
@Test func lyricsApplyTheOffsetTagBySubtractingIt() {
  let lyrics = LyricsParser.parse(
    lrc: "[offset:+500]\n[00:10.00]A\n[00:20.00]B",
    translation: nil,
    romanisation: nil
  )

  #expect(lyrics.lines.map(\.timeSeconds) == [9.5, 19.5])
}

/// An offset larger than the first timestamp would make it negative, which is
/// not a position in a track.
@Test func lyricsClampAnOffsetThatWouldPrecedeTheStart() {
  let lyrics = LyricsParser.parse(
    lrc: "[offset:+5000]\n[00:01.00]A",
    translation: nil,
    romanisation: nil
  )

  #expect(lyrics.lines.map(\.timeSeconds) == [0])
}

@Test func lyricsExpandRepeatedTimestampsOnOneLine() {
  let lyrics = LyricsParser.parse(
    lrc: "[00:10.00][01:10.00]Chorus",
    translation: nil,
    romanisation: nil
  )

  #expect(
    lyrics.lines == [
      LyricLine(timeSeconds: 10, text: "Chorus"),
      LyricLine(timeSeconds: 70, text: "Chorus"),
    ]
  )
}

@Test func lyricsDropMetadataTagsAndUntimedText() {
  let lyrics = LyricsParser.parse(
    lrc: "[ti:Title]\n[ar:Artist]\nloose text\n[00:03.00]Real",
    translation: nil,
    romanisation: nil
  )

  #expect(lyrics.lines == [LyricLine(timeSeconds: 3, text: "Real")])
}

/// Malformed timestamps are external input. They must be skipped, not turned
/// into a line at second zero that would highlight before the song starts.
@Test func lyricsRejectImpossibleTimestamps() {
  let lyrics = LyricsParser.parse(
    lrc: "[00:99.00]TooManySeconds\n[xx:01.00]NotANumber\n[00:05.0000]TooPrecise\n[00:07.00]Good",
    translation: nil,
    romanisation: nil
  )

  #expect(lyrics.lines == [LyricLine(timeSeconds: 7, text: "Good")])
}

@Test func lyricsHighlightTheLineInEffectAtATime() {
  let lyrics = LyricsParser.parse(
    lrc: "[00:10.00]A\n[00:20.00]B\n[00:30.00]C",
    translation: nil,
    romanisation: nil
  )

  #expect(lyrics.lineIndex(at: 0) == nil)
  #expect(lyrics.lineIndex(at: 9.99) == nil)
  #expect(lyrics.lineIndex(at: 10) == 0)
  #expect(lyrics.lineIndex(at: 19.9) == 0)
  #expect(lyrics.lineIndex(at: 20) == 1)
  #expect(lyrics.lineIndex(at: 3600) == 2)
  #expect(Lyrics.none.lineIndex(at: 5) == nil)
}

/// An instrumental, an unindexed upload and a present-but-empty document are
/// three spellings of the same answer, and none of them is a failure.
@Test func lyricsClassifyEveryFormOfHavingNone() throws {
  let noLyric = try NeteaseSession.classifyLyrics(
    data: Data(#"{"code":200,"nolyric":true,"lrc":{"lyric":""}}"#.utf8),
    response: okResponse
  )
  let uncollected = try NeteaseSession.classifyLyrics(
    data: Data(#"{"code":200,"uncollected":true}"#.utf8),
    response: okResponse
  )
  let emptyDocument = try NeteaseSession.classifyLyrics(
    data: Data(#"{"code":200,"lrc":{"lyric":""}}"#.utf8),
    response: okResponse
  )
  let onlyMetadata = try NeteaseSession.classifyLyrics(
    data: Data(#"{"code":200,"lrc":{"lyric":"[ti:X]\n[by:Y]"}}"#.utf8),
    response: okResponse
  )

  #expect(noLyric == .none)
  #expect(uncollected == .none)
  #expect(emptyDocument == .none)
  #expect(onlyMetadata == .none)
}

@Test func lyricsDistinguishServiceAndHTTPErrors() throws {
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyLyrics(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse
    )
  }

  let serverError = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 502,
    httpVersion: nil,
    headerFields: nil
  )!
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 502)) {
    try NeteaseSession.classifyLyrics(data: Data(), response: serverError)
  }
}
