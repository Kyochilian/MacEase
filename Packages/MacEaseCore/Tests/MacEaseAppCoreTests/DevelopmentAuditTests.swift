import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

@MainActor
private struct AuditRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let session: FakeSession
  let arbiter: OperationArbiter
  let library: PlaylistLibraryCoordinator
  let playback: PlaybackController
  let output = FakeAudioOutput()
  init(maximumReads: Int = 6) {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    arbiter = OperationArbiter(maximumConcurrentReads: maximumReads)
    library = PlaylistLibraryCoordinator(transport: transport, vault: vault, arbiter: arbiter)
    playback = PlaybackController(
      transport: transport, vault: vault, arbiter: arbiter, output: output)
    playback.attach(session: session)
  }
}

@Test @MainActor func anUploadKeepsContinuousPlaybackAndLyricsAvailableButProtectsIdentity() async {
  let rig = AuditRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  _ = rig.playback.play(
    tracks: makeTracks([1, 2]), startIndex: 0, context: .dailyRecommendations, session: rig.session)
  await rig.playback.settleForTesting()
  let upload = rig.arbiter.begin(name: "Upload file", effect: .upload)!
  rig.arbiter.markRequestSent(upload)
  #expect(rig.arbiter.begin(name: "Sign out", effect: .sessionMutation) == nil)
  #expect(rig.arbiter.begin(name: "Edit playlist", effect: .write) == nil)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 2)))
  rig.output.onPlayedToEnd?()
  await rig.playback.settleForTesting()
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.phase == .playing)
  let lyrics = LyricsCoordinator(transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  await rig.transport.setLyrics(.success(.lines([LyricLine(timeSeconds: 0, text: "Current")])))
  lyrics.setPanelVisible(true, track: rig.playback.currentTrack, session: rig.session)
  await lyrics.settleForTesting()
  #expect(lyrics.content == .document(.lines([LyricLine(timeSeconds: 0, text: "Current")])))
  #expect(rig.arbiter.end(upload, outcome: .applied) == .applied)
}

@Test @MainActor func aCompletePlaylistPlaysItsLastSongWithOnlyOneReadSlot() async {
  let rig = AuditRig(maximumReads: 1)
  let ids = Array(Int64(1)...1002)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 7, name: "External", trackIDs: ids)))
  await rig.transport.setSongDetailBatches([
    makeTracks(Array(ids.prefix(1000).filter { $0 != 2 }.reversed())),
    makeTracks([1002, 1001]),
  ])
  rig.library.loadTracks(
    for: UserPlaylist(id: 7, name: "External", trackCount: ids.count, owned: false),
    session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.playlists.isEmpty)
  #expect(rig.library.canLoadMoreTracks)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1002)))
  rig.library.playEntirePlaylist(startingAt: 1002, playback: rig.playback, session: rig.session)
  await rig.library.settleForTesting()
  await rig.playback.settleForTesting()
  #expect(rig.playback.queueTracks.map(\.id) == ids.filter { $0 != 2 })
  #expect(rig.playback.currentTrack?.id == 1002)
  #expect(rig.playback.phase == .playing)
  #expect(rig.arbiter.activeReadCount == 0)
}

@Test @MainActor func changingPlaylistCancelsAnUnpublishedCompleteQueue() async {
  let rig = AuditRig()
  let ids = Array(Int64(1)...1001)
  await rig.transport.setPlaylistDetail(.success(PlaylistDetail(id: 1, name: "A", trackIDs: ids)))
  await rig.transport.setSongDetailBatches([makeTracks(Array(ids.prefix(1000)))])
  rig.library.loadTracks(
    for: UserPlaylist(id: 1, name: "A", trackCount: ids.count, owned: false), session: rig.session)
  await rig.library.settleForTesting()
  await rig.transport.setSongDetailBatches([makeTracks([1001]), makeTracks([1001])])
  let arrivals = await rig.transport.gate.arrivalCount()
  await rig.transport.gate.close()
  rig.library.playEntirePlaylist(playback: rig.playback, session: rig.session)
  while await rig.transport.gate.arrivalCount() == arrivals { await Task.yield() }
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 2, name: "B", trackIDs: [1001])))
  rig.library.loadTracks(
    for: UserPlaylist(id: 2, name: "B", trackCount: 1, owned: false), session: rig.session)
  await rig.transport.gate.open()
  await rig.library.settleForTesting()
  #expect(rig.library.selectedPlaylist?.id == 2)
  #expect(rig.playback.queueTracks.isEmpty)
  #expect(rig.library.playlists.isEmpty)
}

@Test @MainActor func artistFullPlaybackLoadsEveryPageAndKeepsItsSource() async {
  let rig = AuditRig(maximumReads: 1)
  let catalog = CatalogCoordinator(transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  let artist = makeArtists([3])[0]
  await rig.transport.setArtistDetail(.success(ArtistDetail(artist: artist, hotSongs: [])))
  await rig.transport.setArtistAlbumPages([CatalogPage(items: [], more: false)])
  catalog.openArtist(id: artist.id, session: rig.session)
  await catalog.settleForTesting()
  await rig.transport.setArtistSongPages([
    CatalogPage(items: makeTracks([11, 12]), more: true),
    CatalogPage(items: makeTracks([12, 13]), more: false),
  ])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 11)))
  catalog.loadArtistSongs(all: true, playback: rig.playback, session: rig.session)
  await catalog.settleForTesting()
  await rig.playback.settleForTesting()
  #expect(catalog.artistSongs.map(\.id) == [11, 12, 13])
  #expect(rig.playback.queueTracks.map(\.id) == [11, 12, 13])
  #expect(rig.playback.queueContext == .artist(id: 3, name: artist.name))
  #expect(!catalog.artistSongsHaveMore)
}

@Test @MainActor func bulkQueueEditsKeepThePlayingEntryAndUseOneRevision() async {
  let rig = AuditRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 2)))
  _ = rig.playback.play(
    tracks: makeTracks([1, 2, 3, 4]), startIndex: 1, context: .playlist(id: 5, name: "List"),
    session: rig.session)
  await rig.playback.settleForTesting()
  let revision = rig.playback.queueRevision
  #expect(
    rig.playback.enqueue(
      makeTracks([4, 5, 4]), next: true, context: .dailyRecommendations,
      accountID: testAccount.userID, revision: revision, session: rig.session))
  #expect(rig.playback.queueTracks.map(\.id) == [1, 2, 4, 5, 3])
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.queueRevision == revision + 1)
  #expect(
    rig.playback.reorderUpcoming(
      songIDs: [3, 5, 4], accountID: testAccount.userID, revision: revision + 1,
      session: rig.session))
  #expect(rig.playback.queueSnapshot?.upcoming.map(\.id) == [3, 5, 4])
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.output.preparedResources.count == 1)
  #expect(
    !rig.playback.reorderUpcoming(
      songIDs: [4, 5, 3], accountID: testAccount.userID, revision: revision, session: rig.session))
}

@Test @MainActor func savedLyricsAndOffsetsSurviveAColdOfflineCoordinatorWithoutCrossingAccounts()
  async throws
{
  let rig = AuditRig()
  let store = try LibraryStore(path: LibraryStore.inMemoryPath)
  let document = Lyrics.attributedLines(
    [
      LyricLine(
        timeSeconds: 1, text: "line", translation: "译文", romanisation: "romaji",
        words: [LyricWord(startSeconds: 1, durationSeconds: 1, text: "line")])
    ], LyricAttribution(contributor: "Author", translationContributor: nil))
  try await store.saveLyrics(document, accountID: testAccount.userID, songID: 1)
  try await store.saveLyricOffset(0.5, accountID: testAccount.userID, songID: 1)
  rig.session.isOnline = false
  let lyrics = LyricsCoordinator(transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  lyrics.attach(store: store)
  lyrics.setPanelVisible(true, track: makeTracks([1])[0], session: rig.session)
  await lyrics.settleForTesting()
  #expect(lyrics.content == .document(document))
  #expect(lyrics.offsetSeconds == 0.5)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(await lyrics.saveForOffline(track: makeTracks([1])[0], session: rig.session) == nil)
  #expect(try await store.savedLyrics(accountID: testAccount.userID, songID: 1).offset == 0.5)

  let other = FakeSession(account: otherAccount, credential: makeCredential())
  other.isOnline = false
  let otherLyrics = LyricsCoordinator(
    transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  otherLyrics.attach(store: store)
  otherLyrics.setPanelVisible(true, track: makeTracks([1])[0], session: other)
  await otherLyrics.settleForTesting()
  #expect(otherLyrics.content == .notSaved)
  #expect(await rig.transport.recordedCalls().isEmpty)
}

@Test @MainActor func shuffledUpcomingReorderingPreservesThePlayingEntryAndPhysicalTracks() async {
  let rig = AuditRig()
  _ = rig.playback.setPlaybackMode(.shuffle)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  _ = rig.playback.play(
    tracks: makeTracks([1, 2, 3, 4]), startIndex: 0, context: .dailyRecommendations,
    session: rig.session)
  await rig.playback.settleForTesting()
  let newOrder = Array(rig.playback.queueSnapshot!.upcoming.map(\.id).reversed())
  #expect(
    rig.playback.reorderUpcoming(
      songIDs: newOrder, accountID: testAccount.userID, revision: rig.playback.queueRevision,
      session: rig.session))
  #expect(rig.playback.queueSnapshot?.upcoming.map(\.id) == newOrder)
  #expect(rig.playback.queueTracks.map(\.id) == [1, 2, 3, 4])
  #expect(rig.playback.currentTrack?.id == 1)
  #expect(rig.output.preparedResources.count == 1)
}

@Test func localHistoryKeepsActualEventIdentityAndAccountIsolation() async throws {
  let store = try LibraryStore(path: LibraryStore.inMemoryPath)
  let first = ListeningHistoryEntry(
    id: UUID(), track: makeTracks([1])[0], context: .album(id: 7, name: "Album"),
    playedAt: Date(timeIntervalSince1970: 100))
  let second = ListeningHistoryEntry(
    id: UUID(), track: makeTracks([2])[0], context: .downloads,
    playedAt: Date(timeIntervalSince1970: 200))
  try await store.saveListeningHistory(first, accountID: 1)
  try await store.saveListeningHistory(first, accountID: 1)
  try await store.saveListeningHistory(second, accountID: 1)
  #expect(try await store.listeningHistory(accountID: 1) == [second, first])
  #expect(try await store.listeningHistory(accountID: 2).isEmpty)
  try await store.saveSearch("query", accountID: 1)
  #expect(try await store.searchHistory(accountID: 2).isEmpty)
  try await store.clearSearchHistory(accountID: 1)
  #expect(try await store.searchHistory(accountID: 1).isEmpty)
}

@Test @MainActor func aLikedPlaylistIsIdentifiedByTheServiceMarkerAndCannotBeRenamedOrDeleted()
  async
{
  let rig = AuditRig()
  let liked = UserPlaylist(
    id: 17, name: "Unrelated display name", trackCount: 0, owned: true, specialType: 5)
  await rig.transport.setPlaylistPages([UserPlaylistPage(playlists: [liked], more: false)])
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 17, name: liked.name, trackIDs: [])))
  await rig.library.openLikedSongs(session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.selectedPlaylist?.id == 17)
  let before = await rig.transport.callCount()
  rig.library.renameSelectedPlaylist(to: "Rename", session: rig.session)
  rig.library.deletePlaylist(liked, session: rig.session)
  await rig.library.settleForTesting()
  #expect(await rig.transport.callCount() == before)
}

@Test @MainActor func anAuthoritativeEmptyLibraryIsNotReplacedByAnOlderDiskSnapshot() async {
  let rig = AuditRig()
  await rig.transport.setPlaylistPages([UserPlaylistPage(playlists: [], more: false)])
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  rig.library.restore(playlists: makePlaylists([1, 2]))
  #expect(rig.library.playlists.isEmpty)
  #expect(rig.library.collection.freshness == .current)
}
