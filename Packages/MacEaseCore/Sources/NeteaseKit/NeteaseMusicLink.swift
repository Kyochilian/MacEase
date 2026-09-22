import Foundation

package enum NeteaseMusicLink: Equatable, Sendable {
  case song(Int64)
  case album(Int64)
  case artist(Int64)
  case playlist(Int64)

  package init?(url: URL) {
    guard let outer = URLComponents(url: url, resolvingAgainstBaseURL: false),
      outer.scheme == "https" || outer.scheme == "http",
      let host = outer.host?.lowercased(), host == "music.163.com" || host == "y.music.163.com",
      outer.user == nil, outer.password == nil, outer.port == nil
    else { return nil }
    let route: URLComponents
    if let fragment = outer.fragment, fragment.hasPrefix("/") {
      guard let inner = URLComponents(string: fragment) else { return nil }
      route = inner
    } else {
      route = outer
    }
    let ids = (route.queryItems ?? []).filter { $0.name == "id" }
    guard ids.count == 1, let raw = ids[0].value, raw.utf8.allSatisfy({ (48...57).contains($0) }),
      let id = Int64(raw), id > 0
    else { return nil }
    switch route.path {
    case "/song", "/m/song": self = .song(id)
    case "/album", "/m/album": self = .album(id)
    case "/artist", "/m/artist": self = .artist(id)
    case "/playlist", "/m/playlist": self = .playlist(id)
    default: return nil
    }
  }

  package var url: URL {
    let path: String
    let id: Int64
    switch self {
    case .song(let value):
      path = "song"
      id = value
    case .album(let value):
      path = "album"
      id = value
    case .artist(let value):
      path = "artist"
      id = value
    case .playlist(let value):
      path = "playlist"
      id = value
    }
    return URL(string: "https://music.163.com/\(path)?id=\(id)")!
  }
}
