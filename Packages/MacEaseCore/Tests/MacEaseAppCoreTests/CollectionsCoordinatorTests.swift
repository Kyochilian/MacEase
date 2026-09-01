import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P2: the account's own collections.
///
/// The rules are the library's rules: one request per action, no automatic
/// refresh after a write, and a write that changed the server but could not be
/// shown locally is never reported as a plain success.

@MainActor
private struct CollectionsRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let session: FakeSession
  let collections: CollectionsCoordinator

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    collections = CollectionsCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
  }

  func settle() async { await collections.settleForTesting() }
}

func makeAlbums(_ ids: [Int64]) -> [Album] {
  ids.map {
    Album(
      id: $0,
      name: "album-\($0)",
      artists: [ArtistRef(id: 900 + $0, name: "artist")],
      artworkURL: nil,
      trackCount: 10
    )
  }
}

func makeArtists(_ ids: [Int64]) -> [Artist] {
  ids.map {
    Artist(id: $0, name: "artist-\($0)", artworkURL: nil, albumCount: 2, songCount: 20)
  }
}

private func makeCloudSongs(_ ids: [Int64], fileSize: Int64 = 1000) -> [CloudSong] {
  ids.map {
    CloudSong(
      id: $0,
      track: makeTracks([$0])[0],
      fileName: "file-\($0).flac",
      fileSize: fileSize
    )
  }
}

// MARK: - Paging

@Test @MainActor func albumsPageFromTheCountAlreadyHeld() async {
  let rig = CollectionsRig()
  await rig.transport.setAlbumPages([
    CatalogPage(items: makeAlbums([1, 2]), more: true),
    CatalogPage(items: makeAlbums([3]), more: false),
  ])

  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()
  #expect(rig.collections.albumsHaveMore)

  rig.collections.loadAlbums(reset: false, session: rig.session)
  await rig.settle()

  #expect(rig.collections.albums.map(\.id) == [1, 2, 3])
  #expect(rig.collections.albumsHaveMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .collectedAlbums(offset: 0), .collectedAlbums(offset: 2),
    ]
  )
}

/// Asking for more when the server said there is none must not spend a
/// request finding that out again.
@Test @MainActor func loadingMoreIsRefusedOnceTheServerSaidThereIsNone() async {
  let rig = CollectionsRig()
  await rig.transport.setArtistPages([CatalogPage(items: makeArtists([1]), more: false)])

  rig.collections.loadArtists(reset: true, session: rig.session)
  await rig.settle()
  rig.collections.loadArtists(reset: false, session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == 1)
}

@Test @MainActor func resetReplacesRatherThanAppends() async {
  let rig = CollectionsRig()
  await rig.transport.setAlbumPages([
    CatalogPage(items: makeAlbums([1, 2]), more: true),
    CatalogPage(items: makeAlbums([9]), more: false),
  ])

  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()
  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()

  #expect(rig.collections.albums.map(\.id) == [9])
  #expect(
    await rig.transport.recordedCalls() == [
      .collectedAlbums(offset: 0), .collectedAlbums(offset: 0),
    ]
  )
}

// MARK: - Cloud drive

@Test @MainActor func theCloudPageCarriesItsOwnCapacity() async {
  let rig = CollectionsRig()
  await rig.transport.setCloudPages([
    CloudPage(
      songs: makeCloudSongs([1, 2], fileSize: 5_000_000),
      more: false,
      capacity: CloudCapacity(usedBytes: 10_000_000, totalBytes: 60_000_000)
    )
  ])

  rig.collections.loadCloud(reset: true, session: rig.session)
  await rig.settle()

  #expect(rig.collections.cloudSongs.count == 2)
  #expect(
    rig.collections.cloudCapacity
      == CloudCapacity(usedBytes: 10_000_000, totalBytes: 60_000_000)
  )
  #expect(await rig.transport.callCount() == 1)
}

/// Deleting frees exactly the file's own size, which the listing already
/// reported. Refetching the page to learn that would be a second request the
/// button did not promise.
@Test @MainActor func deletingACloudSongAppliesItsSizeWithoutAnotherRequest() async {
  let rig = CollectionsRig()
  let songs = makeCloudSongs([1, 2], fileSize: 5_000_000)
  await rig.transport.setCloudPages([
    CloudPage(
      songs: songs,
      more: false,
      capacity: CloudCapacity(usedBytes: 10_000_000, totalBytes: 60_000_000)
    )
  ])
  rig.collections.loadCloud(reset: true, session: rig.session)
  await rig.settle()

  rig.collections.deleteCloudSong(songs[0], session: rig.session)
  await rig.settle()

  #expect(rig.collections.cloudSongs.map(\.id) == [2])
  #expect(rig.collections.cloudCapacity?.usedBytes == 5_000_000)
  #expect(
    await rig.transport.recordedCalls() == [
      .cloudSongs(offset: 0), .deleteCloudSong(1),
    ]
  )
}

/// Freed space can never take the drive below empty, whatever the server said
/// the file weighed.
@Test @MainActor func freedCloudSpaceNeverGoesNegative() async {
  let rig = CollectionsRig()
  let songs = makeCloudSongs([1], fileSize: 9_000_000)
  await rig.transport.setCloudPages([
    CloudPage(
      songs: songs,
      more: false,
      capacity: CloudCapacity(usedBytes: 1_000, totalBytes: 60_000_000)
    )
  ])
  rig.collections.loadCloud(reset: true, session: rig.session)
  await rig.settle()

  rig.collections.deleteCloudSong(songs[0], session: rig.session)
  await rig.settle()

  #expect(rig.collections.cloudCapacity?.usedBytes == 0)
}

// MARK: - Writes

@Test @MainActor func collectingAnAlbumUpdatesOnlyThatRow() async {
  let rig = CollectionsRig()
  await rig.transport.setAlbumPages([
    CatalogPage(items: makeAlbums([1]), more: false)
  ])
  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()
  #expect(rig.collections.albumCollectionState(for: 2) == .confirmed(false))

  let added = makeAlbums([2])[0]
  rig.collections.setAlbumCollected(true, album: added, session: rig.session)
  await rig.settle()

  #expect(rig.collections.albums.map(\.id) == [2, 1])
  #expect(rig.collections.albumCollectionState(for: 2) == .confirmed(true))
  #expect(
    await rig.transport.recordedCalls() == [
      .collectedAlbums(offset: 0), .setAlbumCollected(2, true),
    ]
  )
}

@Test @MainActor func removingACollectedAlbumConfirmsTheButtonState() async {
  let rig = CollectionsRig()
  let album = makeAlbums([2])[0]
  await rig.transport.setAlbumPages([
    CatalogPage(items: [album], more: false)
  ])
  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()
  #expect(rig.collections.albumCollectionState(for: 2) == .confirmed(true))

  rig.collections.setAlbumCollected(false, album: album, session: rig.session)
  await rig.settle()

  #expect(rig.collections.albumCollectionState(for: 2) == .confirmed(false))
}

@Test @MainActor func unfollowingAnArtistRemovesTheRowWithoutReloading() async {
  let rig = CollectionsRig()
  let artists = makeArtists([1, 2])
  await rig.transport.setArtistPages([CatalogPage(items: artists, more: false)])
  rig.collections.loadArtists(reset: true, session: rig.session)
  await rig.settle()
  #expect(rig.collections.artistFollowState(for: 1) == .confirmed(true))

  rig.collections.setArtistFollowed(false, artist: artists[0], session: rig.session)
  await rig.settle()

  #expect(rig.collections.artists.map(\.id) == [2])
  #expect(rig.collections.artistFollowState(for: 1) == .confirmed(false))
  #expect(await rig.transport.callCount() == 2)
}

@Test @MainActor func followingAnArtistConfirmsTheButtonState() async {
  let rig = CollectionsRig()
  let artist = makeArtists([8])[0]

  #expect(rig.collections.artistFollowState(for: 8) == .unknown)
  rig.collections.setArtistFollowed(true, artist: artist, session: rig.session)
  await rig.settle()

  #expect(rig.collections.artistFollowState(for: 8) == .confirmed(true))
}

/// A collect that lands twice must not put the album in the list twice.
@Test @MainActor func collectingAnAlbumTwiceDoesNotDuplicateTheRow() async {
  let rig = CollectionsRig()
  let album = makeAlbums([2])[0]

  rig.collections.setAlbumCollected(true, album: album, session: rig.session)
  await rig.settle()
  rig.collections.setAlbumCollected(true, album: album, session: rig.session)
  await rig.settle()

  #expect(rig.collections.albums.map(\.id) == [2])
}

/// A server that broke while handling the write says nothing about whether the
/// write landed. That has to reach the user as unresolved, never as a failure
/// they would be invited to repeat.
@Test @MainActor func aServerErrorOnAWriteLeavesTheOutcomeUnresolved() async {
  let rig = CollectionsRig()
  await rig.transport.setWriteResult(
    .failure(NeteaseServiceError(source: .http, statusCode: 503))
  )

  rig.collections.setArtistFollowed(
    true,
    artist: makeArtists([5])[0],
    session: rig.session
  )
  await rig.settle()

  #expect(rig.arbiter.unresolvedOutcomes.map(\.kind) == [.unknown])
  #expect(rig.collections.artists.isEmpty)
  #expect(rig.collections.artistFollowState(for: 5) == .unknown)
}

/// An application-layer refusal *is* an answer: the endpoint decided and said
/// no, so there is nothing for the user to go and check.
@Test @MainActor func aServiceRefusalOnAWriteIsAPlainFailure() async {
  let rig = CollectionsRig()
  await rig.transport.setWriteResult(
    .failure(NeteaseServiceError(source: .service, statusCode: 400))
  )

  rig.collections.setArtistFollowed(
    true,
    artist: makeArtists([5])[0],
    session: rig.session
  )
  await rig.settle()

  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
  #expect(rig.collections.artists.isEmpty)
  #expect(rig.collections.artistFollowState(for: 5) == .unknown)
}

@Test @MainActor func aRemotelyAppliedAlbumWriteDoesNotConfirmTheNewAccount() async {
  let rig = CollectionsRig()
  let album = makeAlbums([5])[0]
  await rig.transport.gate.close()

  rig.collections.setAlbumCollected(true, album: album, session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  let credentialB = makeCredential("b")
  await rig.vault.setStored(credentialB)
  rig.session.account = otherAccount
  rig.session.validatedCredential = credentialB
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.collections.albumCollectionState(for: 5) == .unknown)
  #expect(rig.collections.albums.isEmpty)
  #expect(
    rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly]
  )
}

// MARK: - Session

@Test @MainActor func anIdentityChangeTakesTheCollectionsWithIt() async {
  let rig = CollectionsRig()
  await rig.transport.setAlbumPages([
    CatalogPage(items: makeAlbums([1]), more: true)
  ])
  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()

  rig.collections.reset()

  #expect(rig.collections.albums.isEmpty)
  #expect(rig.collections.albumsHaveMore == false)
  #expect(rig.collections.cloudCapacity == nil)
  #expect(rig.collections.albumCollectionState(for: 1) == .unknown)
}

@Test @MainActor func loadingWithoutAValidatedAccountReleasesTheArbiter() async {
  let rig = CollectionsRig()
  rig.session.account = nil

  rig.collections.loadAlbums(reset: true, session: rig.session)
  await rig.settle()

  #expect(rig.collections.status == "Validate the session before loading collections")
  #expect(rig.arbiter.isBusy == false)
  #expect(rig.arbiter.activeReadCount == 0)
  #expect(await rig.transport.callCount() == 0)
}

/// A result that arrives after the session changed describes an account that
/// is no longer signed in, so it must not be shown.
@Test @MainActor func aPageThatOutlivesItsSessionIsNotPublished() async {
  let rig = CollectionsRig()
  await rig.transport.setAlbumPages([
    CatalogPage(items: makeAlbums([1]), more: false)
  ])
  await rig.transport.gate.close()

  rig.collections.loadAlbums(reset: true, session: rig.session)
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  await rig.vault.setStored(makeCredential("replacement"))
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.collections.albums.isEmpty)
}
