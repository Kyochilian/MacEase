import NeteaseKit

@main
struct GateALyricsProbe {
  static func main() async {
    let outcome = await NeteaseSession().probeLyrics(songID: 347_230)
    let cookie = outcome.setsCookie ? "set-cookie" : "no-set-cookie"
    let status =
      switch outcome.status {
      case .content: "content"
      case .noLyrics: "no-lyrics"
      case .http(let code): "http-\(code)"
      case .service(let code): "service-\(code)"
      case .invalidResponse: "invalid-response"
      case .network: "network"
      }
    print("\(status) \(cookie)")
  }
}
