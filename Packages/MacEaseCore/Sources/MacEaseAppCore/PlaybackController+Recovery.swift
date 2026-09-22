import Foundation
import NeteaseKit

@MainActor
extension PlaybackController {
  package func resolveAndPlay(
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token,
    operation: OperationToken,
    advanceBeforeResolve: Bool = false
  ) async {
    var outcome = OperationOutcome.failed
    defer {
      releaseResolution(operation, outcome: outcome)
      if gate.accepts(token) {
        playTask = nil
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      guard session.isOnline else {
        phase = .failed
        status = "This track is not downloaded; connect to play it"
        playbackBecameInactive()
        return
      }
      guard
        let credential = try await currentCredential(
          account: account,
          session: session,
          token: token
        )
      else { return }
      requestCredential = credential

      if advanceBeforeResolve {
        guard
          try await advanceRecoveryEntry(
            account: account,
            token: token
          )
        else {
          exhaustRecovery()
          outcome = .applied
          return
        }
        if try await openRecoveryDownloadIfPresent(
          account: account,
          token: token
        ) {
          outcome = .applied
          return
        }
      }

      while true {
        try checkCurrent(token)
        guard let attempt else { throw CancellationError() }
        let currentSongID = attempt.songID
        let currentQuality = attempt.recovery.currentQuality
        playbackAccountID = account.userID
        status = recoveryStatus(
          prefix: "Resolving",
          attempt: attempt
        )

        let resolution: SongURLResolution
        if let cloudID = currentTrack?.cloudFileID {
          resolution = try await transport.resolveCloudURL(
            songID: cloudID, quality: currentQuality, credential: credential)
        } else {
          resolution = try await transport.resolveSongURL(
            songID: currentSongID, quality: currentQuality, credential: credential)
        }
        try checkCurrent(token)
        guard
          try await sessionRemainsCurrent(
            account: account,
            credential: credential,
            session: session,
            token: token
          )
        else { return }

        outcome = .applied
        switch resolution {
        case .unavailable(let itemCode, let fee):
          if currentTrack?.cloudFileID == nil,
            advanceRecoveryQuality(
              reason: "itemCode=\(itemCode), fee=\(fee.map(String.init) ?? "none")"
            )
          {
            continue
          }
          guard try await advanceRecoveryEntry(account: account, token: token) else {
            exhaustRecovery()
            return
          }
          if try await openRecoveryDownloadIfPresent(
            account: account,
            token: token
          ) {
            return
          }

        case .resolved(let resolved):
          do {
            playbackAccountID = account.userID
            let playable = try await startPlayback(
              asset: resolved,
              accountID: account.userID,
              token: token
            )
            if playable { return }
            if advanceRecoveryQuality(reason: "resolved asset was not playable") {
              continue
            }
          } catch AudioOutputFailure.resourceUnavailable(let statusCode)
            where PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: statusCode)
          {
            releasePlayback()
            if beginFreshResolveForCurrentResource() {
              status = recoveryStatus(
                prefix: "HTTP \(statusCode); re-resolving once",
                attempt: self.attempt
              )
              continue
            }
            if advanceRecoveryQuality(
              reason: "HTTP \(statusCode) after fresh resolve"
            ) {
              continue
            }
          }

          guard try await advanceRecoveryEntry(account: account, token: token) else {
            exhaustRecovery()
            return
          }
          if try await openRecoveryDownloadIfPresent(
            account: account,
            token: token
          ) {
            return
          }
        }
      }
    } catch {
      outcome = Task.isCancelled ? .cancelled : .failed
      guard gate.accepts(token), !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        readToken: operation,
        session: session,
        token: token
      )
    }
  }

  private func startPlayback(
    asset resolved: ResolvedAudioAsset,
    accountID: Int64,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    // A throw here means the asset could not be loaded at all, most often
    // because the URL expired. The attempt survives so Play Again can
    // re-resolve; it is never reused with the stale URL.
    let resource = PlaybackResource(
      location: .remote(resolved.url),
      accountID: accountID,
      songID: resolved.songID,
      requestedQuality: resolved.requestedQuality,
      actualQuality: resolved.actualQuality,
      format: resolved.format,
      byteCount: resolved.byteCount,
      expiresAt: resolved.expiresIn.flatMap {
        $0 > 0 ? Date().addingTimeInterval(TimeInterval($0)) : nil
      },
      representationID: resolved.fileMD5.map { "md5:" + $0 }
    )
    return try await startPlayback(
      resource: resource,
      summary: assetSummary(resolved, attempt: attempt),
      unplayableStatus: "Resolved asset is not playable: " + assetSummary(resolved),
      token: token
    )
  }

  package func openLocal(
    resource: PlaybackResource,
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async {
    let downloadID = resource.accountID.map {
      OfflineDownloadID(
        accountID: $0,
        songID: resource.songID,
        requestedQuality: resource.requestedQuality
      )
    }
    do {
      guard
        let access = await waitForPlaybackAdmission(effect: .localSessionAccess, token: token)
      else { return }
      let credential: NeteaseCredential?
      do {
        credential = try await currentCredential(account: account, session: session, token: token)
        arbiter.end(access, outcome: .applied)
      } catch {
        arbiter.end(access, outcome: .cancelled)
        throw error
      }
      guard credential != nil else { return }
      let quality = resource.actualQuality ?? resource.requestedQuality.rawValue
      let isPlayable = try await startPlayback(
        resource: resource,
        summary: localAssetSummary(resource, actualQuality: quality),
        unplayableStatus: "Downloaded audio is not playable",
        token: token
      )
      if !isPlayable, let downloadID {
        offlineDownloads?.invalidatePlaybackResource(downloadID)
      }
      guard isPlayable else {
        await continueOnlineAfterLocalFailure(
          account: account,
          session: session,
          token: token
        )
        return
      }
    } catch {
      guard gate.accepts(token), !Task.isCancelled else { return }
      releasePlayback()
      if let downloadID {
        offlineDownloads?.invalidatePlaybackResource(downloadID)
      }
      await continueOnlineAfterLocalFailure(
        account: account,
        session: session,
        token: token
      )
    }
  }

  private func continueOnlineAfterLocalFailure(
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async {
    guard gate.accepts(token), !Task.isCancelled else { return }
    guard attempt != nil else {
      phase = .failed
      status = "Downloaded audio failed without a current playback attempt"
      playbackBecameInactive()
      return
    }
    guard let operation = claimResolution() else {
      phase = .failed
      status = "Downloaded audio was removed; online recovery is busy; use Play Again"
      finishLifecycle()
      playbackBecameInactive()
      return
    }
    operationToken = operation
    playbackAccountID = account.userID
    phase = .resolving
    status = "Downloaded audio was invalid; resolving online audio"
    await resolveAndPlay(
      account: account,
      session: session,
      token: token,
      operation: operation
    )
  }

  private func beginFreshResolveForCurrentResource() -> Bool {
    guard var attempt else { return false }
    let started = attempt.recovery.beginFreshResolve(
      songID: attempt.songID,
      quality: attempt.recovery.currentQuality
    )
    self.attempt = attempt
    return started
  }

  private func advanceRecoveryQuality(reason: String) -> Bool {
    guard var attempt, let next = attempt.recovery.advanceQuality() else {
      return false
    }
    self.attempt = attempt
    status = recoveryStatus(
      prefix: "\(reason); trying \(next.rawValue)",
      attempt: attempt
    )
    return true
  }

  private func advanceRecoveryEntry(
    account: NeteaseAccount,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    try checkCurrent(token)
    guard
      let target = queue?.nextIndex(),
      queueTracks.indices.contains(target),
      let currentAttempt = attempt,
      let nextAttempt = currentAttempt.advancing(
        to: queueTracks[target].id,
        queueIndex: target
      )
    else { return false }

    finishLifecycle()
    releasePlayback()
    guard queue?.moveTo(target) == true else { return false }
    queueDidAdvance()
    attempt = nextAttempt
    trackName = queueTracks[target].name
    playbackAccountID = account.userID
    phase = .resolving
    movePosition(to: 0)
    status = recoveryStatus(
      prefix: "Skipping an unavailable entry",
      attempt: nextAttempt
    )
    notifyPlaybackChanged()
    return true
  }

  private func openRecoveryDownloadIfPresent(
    account: NeteaseAccount,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    guard let attempt else { return false }
    guard
      let resource = localResource(
        songID: attempt.songID,
        requestedQuality: attempt.quality,
        accountID: account.userID
      )
    else { return false }
    let downloadID = OfflineDownloadID(
      accountID: account.userID,
      songID: attempt.songID,
      requestedQuality: attempt.quality
    )
    do {
      playbackAccountID = account.userID
      let actual = resource.actualQuality ?? resource.requestedQuality.rawValue
      let playable = try await startPlayback(
        resource: resource,
        summary: localAssetSummary(resource, actualQuality: actual),
        unplayableStatus: "Downloaded audio is not playable",
        token: token
      )
      if playable { return true }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      releasePlayback()
    }
    offlineDownloads?.invalidatePlaybackResource(downloadID)
    playbackAccountID = account.userID
    status = recoveryStatus(
      prefix: "Downloaded audio was invalid; trying online",
      attempt: self.attempt
    )
    return false
  }

  private func exhaustRecovery() {
    let exhaustedAttempt = attempt
    finishLifecycle()
    attempt = nil
    releasePlayback()
    phase = .failed
    status =
      "No playable quality remained"
      + failureQualitySummary(exhaustedAttempt)
      + "; automatic recovery stopped"
    playbackBecameInactive()
  }

  package func recoveryStatus(
    prefix: String,
    attempt: PlaybackAttempt?
  ) -> String {
    guard let attempt else { return prefix }
    let current = attempt.recovery.currentQuality
    return
      "\(prefix): requestedQuality=\(attempt.recovery.requestedQuality.rawValue), "
      + "currentQuality=\(current.rawValue), "
      + "degraded=\(current != attempt.recovery.requestedQuality), "
      + "skipped=\(attempt.recovery.skippedEntries)"
  }

  private func startPlayback(
    resource: PlaybackResource,
    summary: String,
    unplayableStatus: String,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    // A cancelled local task may not have reached AudioOutput before its
    // replacement intent starts. Reject it before it can tear down or observe
    // the replacement player's resource.
    try checkCurrent(token)
    observeOutput(token: token)
    if case .local = resource.location, let accountID = resource.accountID {
      activeOfflineDownloadID = OfflineDownloadID(
        accountID: accountID,
        songID: resource.songID,
        requestedQuality: resource.requestedQuality
      )
    } else {
      activeOfflineDownloadID = nil
    }
    let info = try await output.prepare(
      resource: resource,
      userAgent: "MacEasePhase0/0.1 (macOS 15)"
    )
    try checkCurrent(token)
    guard info.isPlayable else {
      releasePlayback()
      status = unplayableStatus
      return false
    }

    hasLoadedItem = true

    let resumePosition = attempt?.resumePosition ?? 0
    let desiredState = attempt?.desiredState ?? .playing
    if resumePosition > 0 {
      try await output.seek(to: resumePosition)
      try checkCurrent(token)
    }
    movePosition(to: resumePosition)
    durationSeconds = info.durationSeconds
    currentAssetSummary = summary
    switch desiredState {
    case .playing:
      output.play()
      phase = .playing
      status = "Playing: " + summary
    case .paused:
      // It failed while paused; restoring it must not start playback.
      phase = .paused
      status = "Restored paused: " + summary
    }
    return true
  }

}
