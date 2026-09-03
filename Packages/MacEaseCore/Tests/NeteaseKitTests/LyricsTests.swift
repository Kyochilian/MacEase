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

@Test func lyricsPreferValidatedYRCAndItsCompanionDocuments() throws {
  let lyrics = try NeteaseSession.classifyLyrics(
    data: Data(try #require(
      """
      {
        "code": 200,
        "lrc": {"lyric": "[00:01.00]LRC fallback\\n"},
        "yrc": {"lyric": "{\\\"t\\\":0}\\n[1000,1200](1000,500,0)One (1500,700,0)line\\n[3000,800](3000,800,0)Two"},
        "tlyric": {"lyric": "[00:01.00]ordinary translation"},
        "ytlrc": {"lyric": "[00:01.12]逐字翻译\\n[00:03.00]第二行"},
        "romalrc": {"lyric": "[00:01.00]ordinary romanisation"},
        "yromalrc": {"lyric": "[00:01.08]ichi\\n[00:03.00]ni"}
      }
      """.data(using: .utf8)
    )),
    response: okResponse
  )

  #expect(lyrics.lines.count == 2)
  #expect(lyrics.lines[0].timeSeconds == 1)
  #expect(lyrics.lines[0].text == "One line")
  #expect(lyrics.lines[0].translation == "逐字翻译")
  #expect(lyrics.lines[0].romanisation == "ichi")
  #expect(
    lyrics.lines[0].words == [
      LyricWord(startSeconds: 1, durationSeconds: 0.5, text: "One "),
      LyricWord(startSeconds: 1.5, durationSeconds: 0.7, text: "line"),
    ]
  )
  #expect(lyrics.lines[1].text == "Two")
  #expect(lyrics.lines[1].translation == "第二行")
  #expect(lyrics.lines[1].romanisation == "ni")
}

@Test func lyricsWordSelectionUsesHalfOpenTimingBoundaries() {
  let line = LyricLine(
    timeSeconds: 1,
    text: "ABC",
    words: [
      LyricWord(startSeconds: 1, durationSeconds: 0.5, text: "A"),
      LyricWord(startSeconds: 1.5, durationSeconds: 0.25, text: "B"),
      LyricWord(startSeconds: 1.75, durationSeconds: 0.25, text: "C"),
    ]
  )

  #expect(line.wordIndex(at: 0.999) == nil)
  #expect(line.wordIndex(at: 1) == 0)
  #expect(line.wordIndex(at: 1.499) == 0)
  #expect(line.wordIndex(at: 1.5) == 1)
  #expect(line.wordIndex(at: 1.75) == 2)
  #expect(line.wordIndex(at: 2) == nil)
  #expect(line.wordIndex(at: .nan) == nil)
  #expect(line.wordIndex(at: .infinity) == nil)
  #expect(line.wordIndex(at: -.infinity) == nil)
}

@Test func blankAndMalformedYRCAlwaysFallsBackToTheCompleteLRC() {
  let malformed = [
    " ",
    "[-1,1000](0,500,0)negative line",
    "[1000,-1](1000,500,0)negative duration",
    "[1000,1000](-1,500,0)negative",
    "[9223372036854775807,1](9223372036854775807,1,0)line end overflow",
    "[1000,9223372036854775807](1000,1,0)duration overflow",
    "[1000,1000](9223372036854775807,1,0)word end overflow",
    "[1000,1000](1000,500,0broken",
    "[1000,1000(1000,500,0)missing line bracket",
    "[2000,500](2000,500,0)later\n[1000,500](1000,500,0)earlier",
    "[1000,1000](1000,800,0)first(1500,400,0)overlap",
    "[1000,1000](1500,400,0)later(1000,400,0)out of order",
    "[1000,1000](1000,1000,0)first\n[1500,500](1500,500,0)line overlap",
    "[1000,0](1000,1,0)zero line",
    "[1000,1000](1000,0,0)zero word",
    "[1000,1000](900,500,0)outside line",
    "[1000,1000](1600,500,0)past line end",
    "[1000,1000](9223372036854775808,1,0)overflow",
    "{not valid JSON}",
    "[1000,1000](1000,500,0)",
  ]

  for yrc in malformed {
    let lyrics = LyricsParser.parse(
      lrc: "[00:02.00]Fallback",
      yrc: yrc,
      translation: nil,
      romanisation: nil
    )
    #expect(
      lyrics.lines == [LyricLine(timeSeconds: 2, text: "Fallback")],
      "unexpected partial YRC for \(yrc)"
    )
  }
}

@Test func oversizedYRCIsRejectedBeforeParsing() {
  let oversized = String(
    repeating: "x",
    count: LyricsParser.maximumDocumentBytes + 1
  )
  let lyrics = LyricsParser.parse(
    lrc: "[00:02.00]Fallback",
    yrc: oversized,
    translation: nil,
    romanisation: nil
  )

  #expect(lyrics.lines == [LyricLine(timeSeconds: 2, text: "Fallback")])
}

@Test func everyLyricDocumentHasTheSameResponseSizeBound() {
  let oversized = String(
    repeating: "x",
    count: LyricsParser.maximumDocumentBytes + 1
  )

  #expect(
    LyricsParser.parse(
      lrc: oversized,
      translation: nil,
      romanisation: nil
    ) == .none
  )
  let lyrics = LyricsParser.parse(
    lrc: "[00:02.00]Original",
    translation: oversized,
    romanisation: oversized
  )
  #expect(lyrics.lines == [LyricLine(timeSeconds: 2, text: "Original")])
}

@Test func oversizedLyricResponsesAreRejectedBeforeJSONDecoding() {
  let oversized = Data(
    repeating: 0x20,
    count: LyricsParser.maximumResponseBytes + 1
  )

  #expect(throws: DecodingError.self) {
    try NeteaseSession.classifyLyrics(data: oversized, response: okResponse)
  }
}

@Test func mismatchedVerbatimCompanionsNeverReuseOrGuessLines() {
  let lyrics = LyricsParser.parse(
    lrc: "[00:01.00]A\n[00:03.00]B",
    yrc: "[1000,500](1000,500,0)A\n[3000,500](3000,500,0)B",
    translation: "[00:01.10]Only match\n[00:09.00]Unrelated",
    romanisation: "[00:02.50]Too far",
  )

  #expect(lyrics.lines.map(\.translation) == ["Only match", nil])
  #expect(lyrics.lines.map(\.romanisation) == [nil, nil])
}

@Test func japaneseLyricsFillOnlyMissingRomanisationLocally() throws {
  let lyrics = LyricsParser.parse(
    lrc: "[00:01.00]こんにちは\n[00:03.00]世界",
    translation: nil,
    romanisation: "[00:01.00]checked reading"
  )

  #expect(lyrics.lines[0].romanisation == "checked reading")
  let generated = try #require(lyrics.lines[1].romanisation)
  #expect(!generated.isEmpty)
  #expect(generated != lyrics.lines[1].text)

  let nonJapanese = LyricsParser.parse(
    lrc: "[00:01.00]中文歌词",
    translation: nil,
    romanisation: nil
  )
  #expect(nonJapanese.lines[0].romanisation == nil)
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
  #expect(lyrics.lineIndex(at: .nan) == nil)
  #expect(lyrics.lineIndex(at: .infinity) == nil)
  #expect(lyrics.lineIndex(at: -.infinity) == nil)
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

@Test func instrumentalMarkerGetsADedicatedDocumentAndKeepsCredits() throws {
  let lyrics = try NeteaseSession.classifyLyrics(
    data: Data((
      #"{"code":200,"lrc":{"lyric":"[00:00.00]作词：无\n[00:01.00]纯音乐，请欣赏"},"#
        + #""lyricUser":{"nickname":" lyric contributor "},"#
        + #""transUser":{"nickname":"translator"}}"#
    ).utf8),
    response: okResponse
  )

  #expect(lyrics.isInstrumental)
  #expect(lyrics.lines.isEmpty)
  #expect(lyrics.attribution?.contributor == "lyric contributor")
  #expect(lyrics.attribution?.translationContributor == "translator")
  #expect(!lyrics.isEmpty)
}

@Test func ordinaryLyricsExposeAContributorWithoutChangingTheirLines() throws {
  let lyrics = try NeteaseSession.classifyLyrics(
    data: Data((
      #"{"code":200,"lrc":{"lyric":"[00:01.00]Line"},"#
        + #""lyricUser":{"nickname":"Alice"}}"#
    ).utf8),
    response: okResponse
  )

  #expect(lyrics.lines == [LyricLine(timeSeconds: 1, text: "Line")])
  #expect(lyrics.attribution?.contributor == "Alice")
  #expect(!lyrics.isInstrumental)
}

@Test func missingOrMalformedContributorMetadataDoesNotBreakLyrics() throws {
  let missing = try NeteaseSession.classifyLyrics(
    data: Data(#"{"code":200,"lrc":{"lyric":"[00:01.00]Line"}}"#.utf8),
    response: okResponse
  )
  let malformed = try NeteaseSession.classifyLyrics(
    data: Data(
      #"{"code":200,"lrc":{"lyric":"[00:01.00]Line"},"lyricUser":7,"transUser":{"nickname":false}}"#.utf8
    ),
    response: okResponse
  )

  #expect(missing == .lines([LyricLine(timeSeconds: 1, text: "Line")]))
  #expect(malformed == missing)
}

@Test func instrumentalMarkerIsBoundedToSmallMetadataOnlyDocuments() {
  let ordinary = (0..<10).map { "[00:\(String(format: "%02d", $0)).00]Line \($0)" }
  let lyrics = LyricsParser.parse(
    lrc: (ordinary + ["[00:11.00]纯音乐，请欣赏"]).joined(separator: "\n"),
    translation: nil,
    romanisation: nil
  )

  #expect(!lyrics.isInstrumental)
  #expect(lyrics.lines.count == 11)
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
