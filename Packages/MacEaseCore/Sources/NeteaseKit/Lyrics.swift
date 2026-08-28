import Foundation

/// One timed line of a lyric document.
package struct LyricLine: Equatable, Sendable, Codable {
  /// Seconds from the start of the track, with the document's offset already
  /// applied. Never negative.
  package let timeSeconds: Double
  package let text: String
  /// The translated line carrying the same timestamp, when the account's
  /// language settings produced one.
  package let translation: String?
  /// The romanised line carrying the same timestamp.
  package let romanisation: String?

  package init(
    timeSeconds: Double,
    text: String,
    translation: String? = nil,
    romanisation: String? = nil
  ) {
    self.timeSeconds = max(0, timeSeconds)
    self.text = text
    self.translation = translation
    self.romanisation = romanisation
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
  ///
  /// Lines are sorted, so this is a binary search: a lyric panel asks on every
  /// clock tick, and a linear scan of a long document per tick is work the
  /// display does not need to repeat.
  package func lineIndex(at seconds: Double) -> Int? {
    let lines = lines
    guard let first = lines.first, seconds >= first.timeSeconds else {
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

/// Turns NetEase's LRC payloads into one timed document.
///
/// The three payloads — original, translation and romanisation — are separate
/// LRC documents that share timestamps. Merging them here means the panel
/// reads one sorted array instead of keeping three cursors in step, and a
/// translation that NetEase timed differently is dropped rather than attached
/// to the wrong line.
package enum LyricsParser {
  /// LRC timestamps carry at most millisecond precision and are written
  /// either as `.34` or `.340`. Keying the merge on centiseconds makes those
  /// two spellings the same key without any tolerance window.
  private static func mergeKey(_ seconds: Double) -> Int {
    Int((seconds * 100).rounded())
  }

  package static func parse(
    lrc: String?,
    translation: String?,
    romanisation: String?
  ) -> Lyrics {
    let base = parseDocument(lrc)
    guard !base.lines.isEmpty else { return .none }

    let translated = indexed(parseDocument(translation))
    let romanised = indexed(parseDocument(romanisation))

    let lines = base.lines.map { line in
      let shifted = line.timeSeconds - base.offsetSeconds
      let key = mergeKey(line.timeSeconds)
      return LyricLine(
        timeSeconds: shifted,
        text: line.text,
        translation: translated[key],
        romanisation: romanised[key]
      )
    }
    // Applying an offset can reorder lines that were seconds apart only
    // because of it, and `lineIndex(at:)` binary-searches.
    return .lines(lines.sorted { $0.timeSeconds < $1.timeSeconds })
  }

  private struct Document {
    var lines: [(timeSeconds: Double, text: String)] = []
    /// `[offset:+n]` in the LRC header, in seconds. Positive means the lyric
    /// should appear earlier, so it is subtracted from every timestamp.
    var offsetSeconds: Double = 0
  }

  private static func indexed(_ document: Document) -> [Int: String] {
    var result: [Int: String] = [:]
    for line in document.lines where !line.text.isEmpty {
      // A repeated timestamp keeps the first line: NetEase emits the chorus
      // twice in some documents and the later copy is the duplicate.
      result[mergeKey(line.timeSeconds)] = result[mergeKey(line.timeSeconds)] ?? line.text
    }
    return result
  }

  private static func parseDocument(_ source: String?) -> Document {
    var document = Document()
    guard let source, !source.isEmpty else { return document }

    for rawLine in source.split(
      omittingEmptySubsequences: false,
      whereSeparator: \.isNewline
    ) {
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
        } else {
          // An unrecognised bracket is a metadata tag such as `[ti:…]`. It is
          // not lyric text, so it is dropped rather than shown.
        }
        remainder = remainder[next...]
      }

      guard !stamps.isEmpty else { continue }
      let text = remainder.trimmingCharacters(in: .whitespaces)
      for stamp in stamps {
        document.lines.append((timeSeconds: stamp, text: text))
      }
    }

    document.lines.sort { $0.timeSeconds < $1.timeSeconds }
    return document
  }

  /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx`. Anything else is not a timestamp.
  private static func timestamp(_ body: Substring) -> Double? {
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else {
      return nil
    }
    let secondsField = parts[1]
    let pieces = secondsField.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count <= 2, let seconds = Int(pieces[0]), (0..<60).contains(seconds)
    else { return nil }
    guard pieces.count == 2 else {
      return Double(minutes * 60 + seconds)
    }
    let fraction = pieces[1]
    guard !fraction.isEmpty, fraction.count <= 3, let value = Int(fraction) else {
      return nil
    }
    let scale: Double =
      switch fraction.count {
      case 1: 10
      case 2: 100
      default: 1000
      }
    return Double(minutes * 60 + seconds) + Double(value) / scale
  }

  private static func offsetTag(_ body: Substring) -> Double? {
    guard body.hasPrefix("offset:") else { return nil }
    let value = body.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
    guard let milliseconds = Int(value) else { return nil }
    return Double(milliseconds) / 1000
  }
}
