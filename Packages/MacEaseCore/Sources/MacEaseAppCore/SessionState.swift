import Foundation
import NeteaseKit

/// Why a session operation established nothing. A failure is never allowed to
/// stand in for "signed out": it means the previous, confirmed state is still
/// the best thing known.
package enum SessionFailure: Equatable, Sendable {
  case service(NeteaseServiceError)
  case transport
  case keychain(CredentialVaultError)
  /// The WebKit cookie jar did not yield a usable session. The payload is a
  /// diagnostic for display only; no logic reads it.
  case cookiesUnusable(String)
  case invalidManualHeader
  /// The service answered, and the answer was "not signed in".
  case notAuthenticated
  case busy
}

/// What is known about Keychain presence. `unknown` must not be rendered as
/// either an absent or a stored session.
package enum StoredSessionPresence: Equatable, Sendable {
  case unknown
  case absent
  case stored
}

/// The committed session state. Presence and the validated credential move
/// together through the reducer, so no path can leave one set and the other
/// stale.
package struct SessionSnapshot: Equatable, Sendable {
  package enum Presence: Equatable, Sendable {
    /// The Keychain has not been read yet.
    case unknown
    /// The Keychain holds no session.
    case absent
    /// A session is stored but its identity has never been confirmed.
    case storedUnvalidated
    /// A session is stored and the service confirmed this account for it.
    case validated(NeteaseAccount)
    case offline(NeteaseAccount)
  }

  package var presence: Presence
  package var validatedCredential: NeteaseCredential?
  package var offlineCredential: NeteaseCredential?

  package init(
    presence: Presence = .unknown,
    validatedCredential: NeteaseCredential? = nil,
    offlineCredential: NeteaseCredential? = nil
  ) {
    self.presence = presence
    self.validatedCredential = validatedCredential
    self.offlineCredential = offlineCredential
  }

  package var account: NeteaseAccount? {
    switch presence {
    case .validated(let account), .offline(let account): account
    default: nil
    }
  }

  package var storedSessionPresence: StoredSessionPresence {
    switch presence {
    case .unknown: .unknown
    case .absent: .absent
    case .storedUnvalidated, .validated, .offline: .stored
    }
  }
}

/// What an operation established about the stored session.
package enum SessionEvent: Equatable, Sendable {
  /// Launch read of the Keychain.
  case observedStoredItem(present: Bool)
  /// A credential was written but its identity has not been proven.
  case storedNewCredential
  /// The service confirmed this account for this exact credential.
  case validated(NeteaseAccount, NeteaseCredential)
  case restoredOffline(NeteaseAccount, NeteaseCredential)
  /// The stored item was confirmed gone, either by the user or by a
  /// service answer that matched the credential in use.
  case signedOut
  /// The Keychain item is no longer the one the operation started with.
  case storedItemChanged(hasStoredItem: Bool)
  /// A Keychain operation failed after the validated identity was disproved,
  /// so whether an item remains cannot be stated either way.
  case storedItemPresenceUnknown
  /// Nothing was established. Whatever was confirmed before still holds.
  case inconclusive(SessionFailure)
}

/// The outcome the app layer acts on. It replaces reading the status string:
/// callers decide what to reset from the case, never from display text.
package enum SessionMutationResult: Equatable, Sendable {
  /// The same account is still validated. Session-scoped data belongs to that
  /// account and stays valid, so playback and loaded lists are untouched.
  case unchangedValidated(NeteaseAccount)
  /// A different identity is in effect, possibly none. Everything loaded for
  /// the previous identity must go.
  case credentialReplaced(NeteaseAccount?)
  /// The stored session is confirmed gone.
  case signedOut
  /// A credential is stored but unproven; nothing may be treated as
  /// validated, and the previous account must not be carried over.
  case storedUnvalidated
  /// The validated identity is gone, but a Keychain failure left storage
  /// presence unknown. Session-scoped app data must still be cleared.
  case storedPresenceUnknown
  /// Nothing was established; previously confirmed state is preserved.
  case rejected(SessionFailure)
}

/// The one place a session transition is committed.
///
/// Before this existed, `validateSession` cleared the account and the
/// validated credential before it had read anything, and the Session tab
/// stopped playback and cleared the library before the operation ran. A
/// timeout, a Keychain error or any non-301 service error therefore destroyed
/// known-good state that the user then could not get back without a
/// successful retry.
package enum SessionReducer {
  package static func reduce(
    _ snapshot: SessionSnapshot,
    _ event: SessionEvent
  ) -> (SessionSnapshot, SessionMutationResult) {
    switch event {
    case .observedStoredItem(let present):
      guard present else {
        return (SessionSnapshot(presence: .absent), .signedOut)
      }
      if case .validated(let account) = snapshot.presence {
        return (snapshot, .unchangedValidated(account))
      }
      return (SessionSnapshot(presence: .storedUnvalidated), .storedUnvalidated)

    case .storedNewCredential:
      // Saving proves storage, never identity. The previous account cannot be
      // carried over onto a credential nobody has validated.
      return (SessionSnapshot(presence: .storedUnvalidated), .storedUnvalidated)

    case .restoredOffline(let account, let credential):
      return (
        SessionSnapshot(presence: .offline(account), offlineCredential: credential),
        .credentialReplaced(account)
      )

    case .validated(let account, let credential):
      let next = SessionSnapshot(
        presence: .validated(account),
        validatedCredential: credential
      )
      // Session-scoped data is scoped to the account, not to the cookie, so a
      // refreshed credential for the same user keeps everything loaded.
      if snapshot.account?.userID == account.userID {
        return (next, .unchangedValidated(account))
      }
      return (next, .credentialReplaced(account))

    case .signedOut:
      return (SessionSnapshot(presence: .absent), .signedOut)

    case .storedItemChanged(let hasStoredItem):
      let next = SessionSnapshot(
        presence: hasStoredItem ? .storedUnvalidated : .absent
      )
      guard snapshot.account != nil else {
        return (next, hasStoredItem ? .storedUnvalidated : .signedOut)
      }
      return (next, .credentialReplaced(nil))

    case .storedItemPresenceUnknown:
      return (SessionSnapshot(), .storedPresenceUnknown)

    case .inconclusive(let failure):
      return (snapshot, .rejected(failure))
    }
  }

  /// Maps a coordinator's observation of the stored item onto the same
  /// transition, so those paths cannot invent their own.
  package static func event(for divergence: SessionDivergence) -> SessionEvent {
    switch divergence {
    case .storedSessionMissing:
      .storedItemChanged(hasStoredItem: false)
    case .storedSessionChanged(let hasStoredItem):
      .storedItemChanged(hasStoredItem: hasStoredItem)
    }
  }
}
