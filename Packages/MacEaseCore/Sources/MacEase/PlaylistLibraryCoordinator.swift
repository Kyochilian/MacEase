import Foundation
import MacEaseSession
import NeteaseKit
import Observation

@MainActor
@Observable
final class PlaylistLibraryCoordinator {
  private static let pageSize = 30

  @ObservationIgnored private let session = NeteaseSession()
  @ObservationIgnored private let vault = CredentialVault()
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  var playlists: [UserPlaylist] = []
  var hasMore = false
  var isLoading = false
  var status = "Validate the session before loading playlists"

  func load(reset: Bool, loginCoordinator: LoginCoordinator) {
    guard !loginCoordinator.isBusy else { return }
    guard !isLoading else { return }
    guard reset || hasMore else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before loading playlists"
      return
    }

    let currentGeneration = generation
    let offset = reset ? 0 : playlists.count
    isLoading = true
    status = "Loading playlists"

    loadTask = Task {
      await load(
        account: account,
        offset: offset,
        reset: reset,
        generation: currentGeneration,
        loginCoordinator: loginCoordinator
      )
    }
  }

  func reset() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    playlists = []
    hasMore = false
    isLoading = false
    status = "Validate the session before loading playlists"
  }

  private func load(
    account: NeteaseAccount,
    offset: Int,
    reset: Bool,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async {
    defer {
      if self.generation == generation {
        isLoading = false
        loadTask = nil
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      guard let credential = try await vault.load() else {
        guard self.generation == generation else { return }
        loginCoordinator.hasStoredSession = false
        loginCoordinator.account = nil
        loginCoordinator.status = "No stored session to validate"
        status = "No stored session to load playlists"
        return
      }
      requestCredential = credential

      let page = try await session.userPlaylists(
        userID: account.userID,
        limit: Self.pageSize,
        offset: offset,
        credential: credential
      )
      guard self.generation == generation else { return }
      guard loginCoordinator.account == account else {
        playlists = []
        hasMore = false
        status = "Session changed; load again"
        return
      }
      let currentCredential = try await vault.load()
      guard currentCredential == credential else {
        loginCoordinator.hasStoredSession = currentCredential != nil
        loginCoordinator.account = nil
        loginCoordinator.status = "Stored session changed; validate again"
        playlists = []
        hasMore = false
        status = "Session changed; validate again"
        return
      }

      if reset {
        playlists = page.playlists
      } else {
        playlists.append(contentsOf: page.playlists)
      }
      hasMore = page.more
      status = "Loaded \(playlists.count) playlists"
    } catch let error as NeteaseServiceError
      where error.source == .service && error.statusCode == 301
    {
      guard self.generation == generation else { return }
      guard let requestCredential else { return }
      let invalidation = await loginCoordinator.invalidateStoredSession(
        matching: requestCredential,
        message: "Playlist session expired; sign in again"
      )
      guard self.generation == generation else { return }
      playlists = []
      hasMore = false
      switch invalidation {
      case .deleted:
        status = "Playlist session expired; sign in again"
      case .notCurrent:
        status = "Session changed; validate again"
      case .failed:
        status = "Playlist session invalidation failed"
      }
    } catch let error as NeteaseServiceError {
      guard self.generation == generation else { return }
      status = "Playlist \(error.source.rawValue) error \(error.statusCode)"
    } catch let error as CredentialVaultError {
      guard self.generation == generation else { return }
      status = "Keychain error \(error.status)"
    } catch {
      guard self.generation == generation else { return }
      status = "Playlist network or response error"
    }
  }
}
