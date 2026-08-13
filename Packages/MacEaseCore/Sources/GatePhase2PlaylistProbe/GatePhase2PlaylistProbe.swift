import Darwin
import Foundation
import NeteaseKit

@main
struct GatePhase2PlaylistProbe {
  static func main() async {
    guard CommandLine.arguments.count == 1 else {
      print("usage: GatePhase2PlaylistProbe")
      exit(2)
    }

    let vault = CredentialVault()
    let credential: NeteaseCredential
    do {
      guard let stored = try await vault.load() else {
        print("result=noStoredSession totalRequests=0")
        exit(3)
      }
      credential = stored
    } catch let error as CredentialVaultError {
      print("result=failed stage=keychain class=keychain status=\(error.status) totalRequests=0")
      exit(5)
    } catch {
      print("result=failed stage=keychain class=invalidResponse totalRequests=0")
      exit(5)
    }

    let session = NeteaseSession()
    let account: NeteaseAccount
    do {
      guard
        case .authenticated(let authenticated) = try await session.accountStatus(
          credential: credential
        )
      else {
        print("result=signedOut stage=accountStatus totalRequests=1")
        exit(4)
      }
      account = authenticated
    } catch let error as NeteaseServiceError {
      print(
        "result=failed stage=accountStatus class=\(error.source.rawValue) "
          + "status=\(error.statusCode) totalRequests=1"
      )
      exit(1)
    } catch is URLError {
      print("result=failed stage=accountStatus class=network totalRequests=1")
      exit(1)
    } catch {
      print("result=failed stage=accountStatus class=invalidResponse totalRequests=1")
      exit(1)
    }

    do {
      let page = try await session.userPlaylists(
        userID: account.userID,
        limit: 30,
        offset: 0,
        credential: credential
      )
      print(
        "result=success accountStatusRequests=1 userPlaylistsRequests=1 totalRequests=2 "
          + "pageCount=\(page.playlists.count) more=\(page.more)"
      )
    } catch let error as NeteaseServiceError {
      print(
        "result=failed stage=userPlaylists class=\(error.source.rawValue) "
          + "status=\(error.statusCode) totalRequests=2"
      )
      exit(1)
    } catch is URLError {
      print("result=failed stage=userPlaylists class=network totalRequests=2")
      exit(1)
    } catch {
      print("result=failed stage=userPlaylists class=invalidResponse totalRequests=2")
      exit(1)
    }
  }
}
