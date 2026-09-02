import Foundation

/// One timed word or short run inside a NetEase verbatim lyric line.
package struct LyricWord: Equatable, Sendable, Codable {
  /// Absolute seconds from the beginning of the track.
  package let startSeconds: Double
  package let durationSeconds: Double
  package let text: String

  package var endSeconds: Double { startSeconds + durationSeconds }

  package init(startSeconds: Double, durationSeconds: Double, text: String) {
    self.startSeconds = startSeconds
    self.durationSeconds = durationSeconds
    self.text = text
  }
}

/// One timed line of a lyric document.
package struct LyricLine: Equatable, Sendable, Codable {
  /// Seconds from the start of the track, with the document's offset already
  /// applied. Never negative.
  package let timeSeconds: Double
  package let text: String
  /// The translated line carrying the same timestamp, when the account's
  /// language settings produced one.
  package var translation: String?
  /// The romanised line carrying the same timestamp.
  package var romanisation: String?
  /// Empty for an ordinary LRC line. YRC words use absolute track times.
  package let words: [LyricWord]

  package init(
    timeSeconds: Double,
    text: String,
    translation: String? = nil,
    romanisation: String? = nil,
    words: [LyricWord] = []
  ) {
    self.timeSeconds = max(0, timeSeconds)
    self.text = text
    self.translation = translation
    self.romanisation = romanisation
    self.words = words
  }

  /// The word whose half-open interval contains `seconds`.
  package func wordIndex(at seconds: Double) -> Int? {
    guard seconds.isFinite, !words.isEmpty else { return nil }
    var low = 0
    var high = words.count - 1
    var candidate: Int?
    while low <= high {
      let middle = (low + high) / 2
      if words[middle].startSeconds <= seconds {
        candidate = middle
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    guard let candidate, seconds < words[candidate].endSeconds else { return nil }
    return candidate
  }
}

/// A parsed lyric document, or the fact that the song has none.
///
/// "No lyrics" is a real answer from the catalogue and is not an error: an
/// instrumental has nothing to show, and reporting that as a failure would put
/// a retry button in front of a user for whom nothing can change.
package enum Lyrics: Equatable, Sendable {
  case none
  case lines([LyricLine])

  package var lines: [LyricLine] {
    switch self {
    case .none: []
    case .lines(let lines): lines
    }
  }

  package var isEmpty: Bool { lines.isEmpty }

  /// The index of the line that should be highlighted at `seconds`, or nil
  /// before the first line starts.
  package func lineIndex(at seconds: Double) -> Int? {
    let lines = lines
    guard seconds.isFinite, let first = lines.first, seconds >= first.timeSeconds else {
      return nil
    }
    var low = 0
    var high = lines.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if lines[middle].timeSeconds <= seconds {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return low
  }
}

/// Turns NetEase's LRC and YRC payloads into one timed document.
package enum LyricsParser {
  /// A lyric response is small in practice. Bounding every document before
  /// splitting it keeps an untrusted response from creating unbounded strings
  /// and arrays in the UI process.
  package static let maximumDocumentBytes = 1_000_000
  /// Six lyric documents plus their small JSON envelope. This guard is applied
  /// before JSON decoding; the per-document bound still decides whether one
  /// malformed YRC should fall back to a valid LRC.
  package static let maximumResponseBytes = maximumDocumentBytes * 8
  private static let maximumLineCount = 10_000
  private static let maximumWordCount = 100_000
  private static let secondaryMatchTolerance = 0.3

  package static func parse(
    lrc: String?,
    yrc: String? = nil,
    translation: String?,
    yrcTranslation: String? = nil,
    romanisation: String?,
    yrcRomanisation: String? = nil
  ) -> Lyrics {
    let lrcDocument = parseDocument(lrc)
    let lrcLines = lrcDocument.lines.map {
      LyricLine(
        timeSeconds: $0.timeSeconds - lrcDocument.offsetSeconds,
        text: $0.text
      )
    }

    // One malformed YRC timing can make every later word highlight wrong. A
    // valid LRC document is a safer complete fallback than a partial karaoke
    // timeline.
    let verbatim = parseYRC(yrc)
    var lines = verbatim ?? lrcLines
    guard !lines.isEmpty else { return .none }

    let usesVerbatim = verbatim != nil
    merge(
      preferred: usesVerbatim ? yrcTranslation : nil,
      fallback: translation,
      into: &lines,
      keyPath: \.translation,
      tolerance: usesVerbatim ? secondaryMatchTolerance : 0.005
    )
    merge(
      preferred: usesVerbatim ? yrcRomanisation : nil,
      fallback: romanisation,
      into: &lines,
      keyPath: \.romanisation,
      tolerance: usesVerbatim ? secondaryMatchTolerance : 0.005
    )
    if JapaneseRomanisation.isJapanese(lines.map(\.text)) {
      for index in lines.indices where lines[index].romanisation == nil {
        lines[index].romanisation = JapaneseRomanisation.transcribe(lines[index].text)
      }
    }
    return .lines(lines)
  }

  private struct Document {
    var lines: [(timeSeconds: Double, text: String)] = []
    /// `[offset:+n]` in the LRC header, in seconds. Positive means the lyric
    /// should appear earlier, so it is subtracted from every timestamp.
    var offsetSeconds: Double = 0
  }

  private static func merge(
    preferred: String?,
    fallback: String?,
    into lines: inout [LyricLine],
    keyPath: WritableKeyPath<LyricLine, String?>,
    tolerance: Double
  ) {
    let preferredLines = adjustedLines(parseDocument(preferred))
    let secondary = preferredLines.isEmpty
      ? adjustedLines(parseDocument(fallback)) : preferredLines
    guard !secondary.isEmpty else { return }

    var minimumCandidate = 0
    for index in lines.indices {
      let target = lines[index].timeSeconds
      while minimumCandidate < secondary.count,
        secondary[minimumCandidate].timeSeconds <= target - tolerance
      {
        minimumCandidate += 1
      }
      guard minimumCandidate < secondary.count else { break }

      var low = minimumCandidate
      var high = secondary.count
      while low < high {
        let middle = (low + high) / 2
        if secondary[middle].timeSeconds < target {
          low = middle + 1
        } else {
          high = middle
        }
      }
      let candidates = [low - 1, low].filter {
        $0 >= minimumCandidate && $0 < secondary.count
      }
      guard let best = candidates.min(by: {
        abs(secondary[$0].timeSeconds - target)
          < abs(secondary[$1].timeSeconds - target)
      }), abs(secondary[best].timeSeconds - target) < tolerance
      else { continue }
      lines[index][keyPath: keyPath] = secondary[best].text
      minimumCandidate = best + 1
    }
  }

  private static func adjustedLines(
    _ document: Document
  ) -> [(timeSeconds: Double, text: String)] {
    document.lines.map {
      (max(0, $0.timeSeconds - document.offsetSeconds), $0.text)
    }
  }

  private static func parseDocument(_ source: String?) -> Document {
    var document = Document()
    guard let source, validSize(source), !source.isEmpty else { return document }

    var parsedLineCount = 0
    for rawLine in source.split(
      omittingEmptySubsequences: false,
      whereSeparator: \.isNewline
    ) {
      guard parsedLineCount < maximumLineCount else { return Document() }
      var remainder = Substring(rawLine)
      var stamps: [Double] = []

      while remainder.first == "[" {
        guard let close = remainder.firstIndex(of: "]") else { break }
        let body = remainder[remainder.index(after: remainder.startIndex)..<close]
        let next = remainder.index(after: close)
        if let seconds = timestamp(body) {
          stamps.append(seconds)
        } else if let offset = offsetTag(body) {
          document.offsetSeconds = offset
        }
        remainder = remainder[next...]
      }

      guard !stamps.isEmpty else { continue }
      let text = remainder.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      for stamp in stamps {
        guard parsedLineCount < maximumLineCount else { return Document() }
        document.lines.append((timeSeconds: stamp, text: text))
        parsedLineCount += 1
      }
    }

    document.lines.sort { $0.timeSeconds < $1.timeSeconds }
    return document
  }

  /// NetEase YRC is `[lineStartMs,lineDurationMs]` followed by one or more
  /// `(wordStartMs,wordDurationMs,kind)text` fragments. Starts are absolute.
  private static func parseYRC(_ source: String?) -> [LyricLine]? {
    guard let source, validSize(source),
      !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    var lines: [LyricLine] = []
    var totalWords = 0
    var previousLineStart: Int64?
    var previousLineEnd: Int64?

    for raw in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if line.first == "{" {
        guard validMetadataLine(line) else { return nil }
        continue
      }
      guard lines.count < maximumLineCount else { return nil }
      guard let close = line.firstIndex(of: "]"), line.first == "[" else { return nil }
      let headStart = line.index(after: line.startIndex)
      let head = line[headStart..<close].split(separator: ",", omittingEmptySubsequences: false)
      guard
        head.count == 2,
        let lineStart = milliseconds(head[0]),
        let lineDuration = milliseconds(head[1]),
        lineDuration > 0,
        let lineEnd = checkedEnd(start: lineStart, duration: lineDuration)
      else { return nil }
      if let previousLineStart, lineStart <= previousLineStart { return nil }
      if let previousLineEnd, lineStart < previousLineEnd { return nil }

      var remainder = line[line.index(after: close)...]
      var words: [LyricWord] = []
      var text = ""
      var previousWordEnd: Int64?
      while !remainder.isEmpty {
        guard remainder.first == "(", let wordClose = remainder.firstIndex(of: ")") else {
          return nil
        }
        let bodyStart = remainder.index(after: remainder.startIndex)
        let body = remainder[bodyStart..<wordClose].split(
          separator: ",",
          omittingEmptySubsequences: false
        )
        guard
          body.count == 3,
          let wordStart = milliseconds(body[0]),
          let wordDuration = milliseconds(body[1]),
          wordDuration > 0,
          milliseconds(body[2]) != nil,
          let wordEnd = checkedEnd(start: wordStart, duration: wordDuration),
          wordStart >= lineStart,
          wordEnd <= lineEnd
        else { return nil }
        if let previousWordEnd, wordStart < previousWordEnd { return nil }

        let contentStart = remainder.index(after: wordClose)
        let tail = remainder[contentStart...]
        let nextWord = tail.firstIndex(of: "(") ?? tail.endIndex
        let piece = String(tail[..<nextWord])
        guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return nil
        }
        words.append(
          LyricWord(
            startSeconds: Double(wordStart) / 1000,
            durationSeconds: Double(wordDuration) / 1000,
            text: piece
          )
        )
        totalWords += 1
        guard totalWords <= maximumWordCount else { return nil }
        text += piece
        previousWordEnd = wordEnd
        remainder = tail[nextWord...]
      }

      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !words.isEmpty else { return nil }
      lines.append(
        LyricLine(
          timeSeconds: Double(lineStart) / 1000,
          text: trimmed,
          words: words
        )
      )
      previousLineStart = lineStart
      previousLineEnd = lineEnd
    }
    return lines.isEmpty ? nil : lines
  }

  private static func validMetadataLine(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
  }

  private static func validSize(_ source: String) -> Bool {
    source.utf8.count <= maximumDocumentBytes
  }

  private static func milliseconds(_ source: Substring) -> Int64? {
    guard !source.isEmpty, source.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return nil
    }
    return Int64(source)
  }

  private static func checkedEnd(start: Int64, duration: Int64) -> Int64? {
    let (end, overflow) = start.addingReportingOverflow(duration)
    return overflow ? nil : end
  }

  /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx`. Anything else is not a timestamp.
  private static func timestamp(_ body: Substring) -> Double? {
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let minutes = Int64(parts[0]), minutes >= 0 else {
      return nil
    }
    let secondsField = parts[1]
    let pieces = secondsField.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count <= 2, let seconds = Int64(pieces[0]), (0..<60).contains(seconds)
    else { return nil }
    let (minuteSeconds, multiplyOverflow) = minutes.multipliedReportingOverflow(by: 60)
    let (wholeSeconds, addOverflow) = minuteSeconds.addingReportingOverflow(seconds)
    guard !multiplyOverflow, !addOverflow else { return nil }
    guard pieces.count == 2 else { return Double(wholeSeconds) }
    let fraction = pieces[1]
    guard !fraction.isEmpty, fraction.count <= 3, let value = Int(fraction) else {
      return nil
    }
    let scale: Double = switch fraction.count {
    case 1: 10
    case 2: 100
    default: 1000
    }
    return Double(wholeSeconds) + Double(value) / scale
  }

  private static func offsetTag(_ body: Substring) -> Double? {
    guard body.hasPrefix("offset:") else { return nil }
    let value = body.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
    guard let milliseconds = Int64(value) else { return nil }
    return Double(milliseconds) / 1000
  }
}

/// NetEase does not supply `romalrc` for every Japanese song. The fixed
/// Kumone baseline fills those gaps locally; Foundation's transliterator gives
/// MacEase the same offline, dependency-free fallback without another source.
private enum JapaneseRomanisation {
  private static let kanaRanges: [ClosedRange<UInt32>] = [
    0x3040...0x309F,
    0x30A0...0x30FF,
    0xFF66...0xFF9D,
  ]

  static func isJapanese(_ lines: [String]) -> Bool {
    let content = lines.filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !content.isEmpty else { return false }
    let kanaLines = content.lazy.filter { line in
      line.unicodeScalars.contains { scalar in
        kanaRanges.contains { $0.contains(scalar.value) }
      }
    }.count
    return kanaLines >= 3 || Double(kanaLines) / Double(content.count) >= 0.2
  }

  static func transcribe(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let transliterated = trimmed.applyingTransform(.toLatin, reverse: false)
    else { return nil }
    let latin = (transliterated.applyingTransform(.stripCombiningMarks, reverse: false)
      ?? transliterated).trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !latin.isEmpty,
      latin.caseInsensitiveCompare(trimmed) != ComparisonResult.orderedSame
    else { return nil }
    return latin
  }
}
