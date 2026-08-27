import MacEaseSession
import NeteaseKit
import Testing

@testable import MacEaseAppCore

private actor BlockingDeleteVault: CredentialStoring {
  private var stored: NeteaseCredential?
  private var deleteStarted = false
  private var deleteBlocked = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(stored: NeteaseCredential?) {
    self.stored = stored
  }

  func blockDelete() { deleteBlocked = true }

  func hasStartedDelete() -> Bool { deleteStarted }

  func releaseDelete() {
    deleteBlocked = false
    waiter?.resume()
    waiter = nil
  }

  func load() throws -> NeteaseCredential? { stored }

  func save(_ credential: NeteaseCredential) throws {
    stored = credential
  }

  func delete() throws {
    stored = nil
  }

  func delete(matching credential: NeteaseCredential) async throws -> Bool {
    guard stored == credential else { return false }
    stored = nil
    deleteStarted = true
    if deleteBlocked {
      await withCheckedContinuation { waiter = $0 }
    }
    return true
  }
}

@Test @MainActor func failedCredentialDeletionInvalidatesEveryModule() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))
  await vault.setDeleteError(CredentialVaultError.keychain(-25300))

  var identityChangeCount = 0
  login.onIdentityChanged = { identityChangeCount += 1 }
  let result = await login.invalidateStoredSession(
    matching: credential,
    message: "Stored session expired; sign in again"
  )

  #expect(result == .failed)
  #expect(login.account == nil)
  #expect(login.storedSessionPresence == .unknown)
  #expect(identityChangeCount == 1)
}

@Test @MainActor func replacedCredentialInvalidatesEveryModuleWithoutDeletingIt() async {
  let credential = makeCredential()
  let replacement = makeCredential("replacement")
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))
  await vault.setStored(replacement)

  var identityChangeCount = 0
  login.onIdentityChanged = { identityChangeCount += 1 }
  let result = await login.invalidateStoredSession(
    matching: credential,
    message: "Stored session expired; sign in again"
  )

  #expect(result == .notCurrent)
  #expect(login.account == nil)
  #expect(login.storedSessionPresence == .stored)
  let stored = try? await vault.load()
  #expect(stored == .some(replacement))
  #expect(identityChangeCount == 1)
}

@Test @MainActor func failedConfirmationDoesNotGuessThatAnItemExists() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))
  await vault.setStored(makeCredential("replacement"))
  await vault.setLoadError(CredentialVaultError.keychain(-25300))

  var identityChangeCount = 0
  login.onIdentityChanged = { identityChangeCount += 1 }
  let result = await login.invalidateStoredSession(
    matching: credential,
    message: "Stored session expired; sign in again"
  )

  #expect(result == .notCurrent)
  #expect(login.account == nil)
  #expect(login.storedSessionPresence == .unknown)
  #expect(identityChangeCount == 1)
}

@Test @MainActor func failedClearDoesNotGuessThatAnItemExists() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))
  await vault.setDeleteError(CredentialVaultError.keychain(-25300))

  let result = await login.clearSession()

  #expect(result == .storedPresenceUnknown)
  #expect(login.account == nil)
  #expect(login.storedSessionPresence == .unknown)
}

@Test @MainActor func promotedInvalidationBlocksImportUntilItFinishes() async throws {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = BlockingDeleteVault(stored: credential)
  let arbiter = OperationArbiter()
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))

  await vault.blockDelete()
  var identityChangeCount = 0
  login.onIdentityChanged = { identityChangeCount += 1 }
  let readToken = arbiter.begin(name: "Playlist", effect: .read)!

  let invalidation = Task { @MainActor in
    await login.invalidateStoredSession(
      matching: credential,
      message: "Stored session expired; sign in again",
      readToken: readToken
    )
  }
  while !(await vault.hasStartedDelete()) { await Task.yield() }

  login.manualCookieHeader = "MUSIC_U=replacement"
  #expect(await login.importSession() == .rejected(.busy))
  #expect(login.matchesValidatedSession(credential, account: testAccount))

  await vault.releaseDelete()
  #expect(await invalidation.value == .deleted)
  #expect(login.account == nil)
  #expect(try await vault.load() == nil)
  #expect(arbiter.end(readToken, outcome: .cancelled) == nil)
  #expect(identityChangeCount == 1)
}

@Test @MainActor func invalidationIsBusyWhileAnotherReadIsActive() async throws {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))

  let playlist = arbiter.begin(name: "Playlist", effect: .read)!
  let discovery = arbiter.begin(name: "Discover", effect: .read)!
  let result = await login.invalidateStoredSession(
    matching: credential,
    message: "Stored session expired; sign in again",
    readToken: playlist
  )

  #expect(result == .busy)
  #expect(login.matchesValidatedSession(credential, account: testAccount))
  #expect(try await vault.load() == credential)
  arbiter.end(playlist, outcome: .failed)
  arbiter.end(discovery, outcome: .applied)
}

@Test @MainActor func validateDeletesTheReplacementCredentialItActuallyChecked() async {
  let credentialA = makeCredential()
  let credentialB = makeCredential("replacement")
  let transport = FakeTransport()
  let vault = FakeVault(stored: credentialA)
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))

  await vault.setStored(credentialB)
  await transport.setAccountStatus(.success(.signedOut))
  #expect(await login.validateSession() == .signedOut)

  #expect(login.account == nil)
  #expect(login.storedSessionPresence == .absent)
  #expect((try? await vault.load()) == nil)
}

@Test @MainActor func playlist301PromotesItsReadBeforeDeletingTheSession() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let login = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  #expect(await login.validateSession() == .credentialReplaced(testAccount))
  await transport.setPlaylistPageError(
    NeteaseServiceError(source: .service, statusCode: 301)
  )

  library.load(reset: true, session: login)
  await library.settleForTesting()

  #expect(login.account == nil)
  #expect(login.storedSessionPresence == .absent)
  #expect((try? await vault.load()) == nil)
  #expect(library.status == "Stored session expired; sign in again")
}
