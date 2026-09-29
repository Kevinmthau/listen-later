import Foundation
import SwiftData
import XCTest
@testable import ListenLater

@MainActor
final class QueueStoreTests: XCTestCase {
    func testVideoShareURLUsesDurableCanonicalPage() {
        let originalURL = URL(
            string: "https://x.com/OpenAI/status/1234567890123456789?s=20"
        )!
        let canonicalURL = URL(
            string: "https://x.com/OpenAI/status/1234567890123456789"
        )!
        let item = QueueItem(
            originalURL: originalURL,
            canonicalURL: canonicalURL,
            source: .socialVideo,
            sortRank: 1_000
        )
        item.playbackURLString = "https://cdn.example.com/temporary-video.mp4"

        XCTAssertEqual(item.videoShareURL, canonicalURL)
        XCTAssertNotEqual(item.videoShareURL, item.playbackURL)
    }

    func testPodcastDoesNotExposeVideoShareURL() {
        let item = QueueItem(
            originalURL: URL(string: "https://example.com/episode")!,
            source: .podcast,
            sortRank: 1_000
        )

        XCTAssertNil(item.videoShareURL)
    }

    func testAddResolvesWithStubProviderAndAppendsAtBottom() async throws {
        let firstURL = URL(string: "https://podcasts.example/episodes/first")!
        let secondURL = URL(string: "https://podcasts.example/episodes/second")!
        let harness = try makeHarness(
            providers: [
                QueueStubProvider(
                    source: .podcast,
                    acceptedHost: "podcasts.example"
                )
            ]
        )

        let firstResult = await harness.store.add(url: firstURL)
        let secondResult = await harness.store.add(url: secondURL)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(harness.store.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(first.title, "Resolved first")
        XCTAssertEqual(first.subtitle, "Stub Podcast")
        XCTAssertEqual(first.source, .podcast)
        XCTAssertEqual(first.status, .ready)
        XCTAssertEqual(
            first.playbackURL?.absoluteString,
            "https://cdn.example.com/first.mp3"
        )
        XCTAssertEqual(first.sortRank, 1_000)
        XCTAssertEqual(second.sortRank, 2_000)
    }

    func testAddRejectsNonHTTPURLWithoutInserting() async throws {
        let harness = try makeHarness(providers: [])
        let result = await harness.store.add(
            url: URL(fileURLWithPath: "/tmp/episode.mp3")
        )

        XCTAssertNil(result)
        XCTAssertTrue(harness.store.items.isEmpty)
        XCTAssertEqual(
            harness.store.lastErrorMessage,
            "Only secure public HTTPS links are supported."
        )
    }

    func testAddAndRefreshSocialVideoUsesExpiringVideoGrabberURL() async throws {
        let url = URL(
            string: "https://x.com/OpenAI/status/1234567890123456789"
        )!
        let harness = try makeHarness(
            providers: [
                QueueStubProvider(
                    source: .socialVideo,
                    acceptedHost: "x.com"
                )
            ]
        )

        let addedResult = await harness.store.add(url: url)
        let added = try XCTUnwrap(addedResult)
        XCTAssertEqual(added.source, .socialVideo)
        XCTAssertEqual(added.status, .ready)
        XCTAssertEqual(
            added.playbackURL,
            URL(string: "https://cdn.example.com/1234567890123456789.mp4")
        )
        XCTAssertFalse(added.playbackURLNeedsRefresh())

        added.playbackURLExpiresAt = .distantPast
        XCTAssertTrue(added.playbackURLNeedsRefresh())
        await harness.store.refreshPlaybackURL(for: added)

        XCTAssertEqual(added.status, .ready)
        XCTAssertFalse(added.playbackURLNeedsRefresh())
    }

    func testReaddingSameXStatusFromDifferentShareURLDoesNotDuplicate() async throws {
        let harness = try makeHarness(
            providers: [
                QueueStubProvider(
                    source: .socialVideo,
                    acceptedHost: "x.com"
                )
            ]
        )
        let firstURL = URL(
            string: "https://x.com/OpenAI/status/1234567890123456789?s=20"
        )!
        let secondURL = URL(
            string: "https://twitter.com/OpenAI/status/1234567890123456789"
        )!

        let firstResult = await harness.store.add(url: firstURL)
        let first = try XCTUnwrap(firstResult)
        let secondResult = await harness.store.add(url: secondURL)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(harness.store.items.count, 1)
        XCTAssertEqual(first.id, second.id)
    }

    func testResumePendingResolutionAfterRelaunch() async throws {
        let url = URL(string: "https://podcasts.example/episodes/interrupted")!
        let harness = try makeHarness(
            providers: [
                QueueStubProvider(
                    source: .podcast,
                    acceptedHost: "podcasts.example"
                )
            ]
        )
        let pending = QueueItem(
            originalURL: url,
            title: "Podcast episode",
            source: .podcast,
            status: .resolving,
            sortRank: 1_000
        )
        harness.container.mainContext.insert(pending)
        try harness.container.mainContext.save()
        harness.store.refresh()

        await harness.store.resumePendingResolutions()

        XCTAssertEqual(pending.status, .ready)
        XCTAssertEqual(pending.title, "Resolved interrupted")
        XCTAssertEqual(
            pending.playbackURL,
            URL(string: "https://cdn.example.com/interrupted.mp3")
        )
    }

    func testDeletingItemDuringResolutionDoesNotResurrectIt() async throws {
        let url = URL(string: "https://podcasts.example/episodes/slow")!
        let gate = QueueResolutionGate()
        let harness = try makeHarness(
            providers: [DelayedQueueProvider(gate: gate)]
        )

        var didReturnItem = false
        let addTask = Task { @MainActor in
            didReturnItem = await harness.store.add(url: url) != nil
        }
        await gate.waitUntilStarted()
        let stagedItem = try XCTUnwrap(harness.store.items.first)
        harness.store.delete(stagedItem)
        await gate.release()

        await addTask.value
        XCTAssertFalse(didReturnItem)
        XCTAssertTrue(harness.store.items.isEmpty)
    }

    func testReaddingDuplicatePreservesPartialProgressButRestartsPlayedItem() async throws {
        let url = URL(string: "https://podcasts.example/episodes/requeue")!
        let harness = try makeHarness(
            providers: [
                QueueStubProvider(
                    source: .podcast,
                    acceptedHost: "podcasts.example"
                )
            ]
        )
        let added = await harness.store.add(url: url)
        let item = try XCTUnwrap(added)
        harness.store.saveProgress(
            for: item,
            position: 123,
            duration: item.duration,
            force: true
        )

        _ = await harness.store.add(url: url)
        XCTAssertEqual(item.playbackPosition, 123)
        XCTAssertFalse(item.isPlayed)

        harness.store.markPlayed(item)
        _ = await harness.store.add(url: url)
        XCTAssertEqual(item.playbackPosition, 0)
        XCTAssertFalse(item.isPlayed)
    }

    func testReorderAndMoveToPlayNextPersistDeterministicRanks() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1)
        let second = appendItem(to: harness.store, ordinal: 2)
        let third = appendItem(to: harness.store, ordinal: 3)
        let fourth = appendItem(to: harness.store, ordinal: 4)

        harness.store.move(from: IndexSet(integer: 3), to: 0)

        XCTAssertEqual(
            harness.store.items.map(\.id),
            [fourth.id, first.id, second.id, third.id]
        )
        XCTAssertEqual(
            harness.store.items.map(\.sortRank),
            [1_000, 2_000, 3_000, 4_000]
        )

        harness.store.moveToPlayNext(third, after: first.id)

        XCTAssertEqual(
            harness.store.items.map(\.id),
            [fourth.id, first.id, third.id, second.id]
        )
        XCTAssertEqual(
            harness.store.items.map(\.sortRank),
            [1_000, 2_000, 3_000, 4_000]
        )
    }

    func testMoveToPlayNextWithoutCurrentMovesItemToFront() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1)
        let second = appendItem(to: harness.store, ordinal: 2)
        let third = appendItem(to: harness.store, ordinal: 3)

        harness.store.moveToPlayNext(third, after: nil)

        XCTAssertEqual(
            harness.store.items.map(\.id),
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(
            harness.store.items.map(\.sortRank),
            [1_000, 2_000, 3_000]
        )
    }

    func testMoveToPlayNextLeavesCurrentItemInPlace() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1)
        let second = appendItem(to: harness.store, ordinal: 2)
        let third = appendItem(to: harness.store, ordinal: 3)
        let originalRanks = harness.store.items.map(\.sortRank)

        harness.store.moveToPlayNext(second, after: second.id)

        XCTAssertEqual(
            harness.store.items.map(\.id),
            [first.id, second.id, third.id]
        )
        XCTAssertEqual(harness.store.items.map(\.sortRank), originalRanks)
    }

    func testMoveUpNextPreservesItemsInPlayedSectionAsOrderingAnchors() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1)
        let played = appendItem(to: harness.store, ordinal: 2)
        let third = appendItem(to: harness.store, ordinal: 3)
        let fourth = appendItem(to: harness.store, ordinal: 4)
        harness.store.markPlayed(played)

        harness.store.moveUpNext(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(
            harness.store.items.map(\.id),
            [fourth.id, played.id, first.id, third.id]
        )
    }

    func testMarkPlayedMarkUnplayedAndDelete() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1, duration: 300)
        let second = appendItem(to: harness.store, ordinal: 2, duration: 600)
        let third = appendItem(to: harness.store, ordinal: 3, duration: 900)

        harness.store.markPlayed(first)
        XCTAssertTrue(first.isPlayed)
        XCTAssertTrue(first.isInPlayedSection)
        XCTAssertNotNil(first.lastPlayedAt)
        XCTAssertEqual(first.playbackPosition, 300)

        harness.store.markUnplayed(first)
        XCTAssertFalse(first.isPlayed)
        XCTAssertFalse(first.isInPlayedSection)
        XCTAssertNil(first.lastPlayedAt)
        XCTAssertEqual(first.playbackPosition, 0)

        harness.store.delete(second)
        XCTAssertEqual(harness.store.items.map(\.id), [first.id, third.id])
        XCTAssertEqual(
            harness.store.items.map(\.sortRank),
            [1_000, 3_000],
            "Deleting leaves other ranks alone so Undo can restore in place."
        )
    }

    func testDeleteAndRestoreRecreateItemsInPlaceWithTheirProgress() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1, duration: 300)
        let second = appendItem(to: harness.store, ordinal: 2, duration: 600)
        let third = appendItem(to: harness.store, ordinal: 3, duration: 900)
        harness.store.saveProgress(for: second, position: 42, force: true)
        harness.store.markPlayed(third)
        let secondID = second.id
        let thirdID = third.id

        let snapshots = harness.store.delete([second, third])
        XCTAssertEqual(snapshots.map(\.id), [secondID, thirdID])
        XCTAssertEqual(harness.store.items.map(\.id), [first.id])

        harness.store.restore(snapshots)

        XCTAssertEqual(harness.store.items.map(\.id), [first.id, secondID, thirdID])
        let restoredSecond = try XCTUnwrap(harness.store.item(id: secondID))
        XCTAssertEqual(restoredSecond.playbackPosition, 42)
        XCTAssertEqual(restoredSecond.title, "Episode 2")
        XCTAssertEqual(restoredSecond.status, .ready)
        let restoredThird = try XCTUnwrap(harness.store.item(id: thirdID))
        XCTAssertTrue(restoredThird.isPlayed)

        harness.store.restore(snapshots)
        XCTAssertEqual(
            harness.store.items.count,
            3,
            "Restoring twice must not duplicate items."
        )
    }

    func testRestoringAnItemThatWasStillResolvingLooksItUpAgain() async throws {
        let harness = try makeHarness(
            providers: [
                QueueStubProvider(source: .podcast, acceptedHost: "podcasts.example")
            ]
        )
        let pending = QueueItem(
            originalURL: URL(string: "https://podcasts.example/episodes/pending")!,
            title: "Podcast episode",
            source: .podcast,
            status: .resolving,
            sortRank: 1_000
        )
        harness.container.mainContext.insert(pending)
        try harness.container.mainContext.save()
        harness.store.refresh()
        let pendingID = pending.id

        // Its lookup finished while it was deleted, so nothing is in flight.
        let snapshots = harness.store.delete([pending])
        harness.store.restore(snapshots)

        let deadline = Date().addingTimeInterval(2)
        while harness.store.item(id: pendingID)?.status == .resolving, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = try XCTUnwrap(harness.store.item(id: pendingID))
        XCTAssertEqual(restored.status, .ready)
        XCTAssertEqual(restored.title, "Resolved pending")
    }

    func testMoveToTopOfUpNextIgnoresPlayedItemsAndSkipsNoOpWrites() throws {
        let harness = try makeHarness()
        let played = appendItem(to: harness.store, ordinal: 1)
        let second = appendItem(to: harness.store, ordinal: 2)
        let third = appendItem(to: harness.store, ordinal: 3)
        harness.store.markPlayed(played)

        let secondRank = second.sortRank
        harness.store.moveToTopOfUpNext(second)
        XCTAssertEqual(second.sortRank, secondRank, "Already first in Up Next.")

        harness.store.moveToTopOfUpNext(third)
        XCTAssertEqual(
            harness.store.items.filter { !$0.isInPlayedSection }.map(\.id),
            [third.id, second.id]
        )
    }

    func testMoveToEndOfUpNextPutsItemAfterEveryUnplayedItem() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1)
        let second = appendItem(to: harness.store, ordinal: 2)
        let third = appendItem(to: harness.store, ordinal: 3)

        harness.store.moveToEndOfUpNext(first)

        XCTAssertEqual(
            harness.store.items.map(\.id),
            [second.id, third.id, first.id]
        )
    }

    func testFirstUnplayedCanExcludeTheCurrentItem() throws {
        let harness = try makeHarness()
        let first = appendItem(to: harness.store, ordinal: 1)
        let second = appendItem(to: harness.store, ordinal: 2)

        XCTAssertEqual(harness.store.firstUnplayed()?.id, first.id)
        XCTAssertEqual(harness.store.firstUnplayed(excluding: first.id)?.id, second.id)
        XCTAssertEqual(harness.store.firstUnplayed(excluding: second.id)?.id, first.id)
    }

    func testSocialVideoSourceNameUsesThePlatform() {
        let x = QueueItem(
            originalURL: URL(string: "https://x.com/OpenAI/status/1234567890123456789")!,
            source: .socialVideo,
            sortRank: 1_000
        )
        let instagram = QueueItem(
            originalURL: URL(string: "https://www.instagram.com/reel/DR8LMPxEoiO/")!,
            source: .socialVideo,
            sortRank: 2_000
        )
        let podcast = QueueItem(
            originalURL: URL(string: "https://podcasts.example/episodes/1")!,
            source: .podcast,
            sortRank: 3_000
        )

        XCTAssertEqual(x.sourceName, "X")
        XCTAssertEqual(instagram.sourceName, "Instagram")
        XCTAssertEqual(podcast.sourceName, "Podcast")
    }

    func testSaveProgressThrottlesClampsPersistsRateWithoutMarkingPlayed() throws {
        let harness = try makeHarness()
        let item = appendItem(to: harness.store, ordinal: 1, duration: 100)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        harness.store.saveProgress(
            for: item,
            position: 10,
            duration: 200,
            rate: 1.25,
            now: start
        )
        XCTAssertEqual(item.playbackPosition, 10)
        XCTAssertEqual(item.duration, 200)
        XCTAssertEqual(item.playbackRate, 1.25)
        XCTAssertFalse(item.isPlayed)

        harness.store.saveProgress(
            for: item,
            position: 99,
            rate: 2,
            now: start.addingTimeInterval(4)
        )
        XCTAssertEqual(item.playbackPosition, 10, "Writes inside five seconds are throttled.")
        XCTAssertEqual(item.playbackRate, 1.25)

        harness.store.saveProgress(
            for: item,
            position: 198.5,
            now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(item.playbackPosition, 198.5)
        XCTAssertFalse(item.isPlayed)

        harness.store.saveProgress(
            for: item,
            position: 200,
            now: start.addingTimeInterval(6),
            force: true
        )
        XCTAssertEqual(item.playbackPosition, 200)
        XCTAssertFalse(item.isPlayed)

        harness.store.saveProgress(
            for: item,
            position: -30,
            now: start.addingTimeInterval(7),
            force: true
        )
        XCTAssertEqual(item.playbackPosition, 0)
        XCTAssertFalse(item.isPlayed)
    }

    func testYouTubeProgressDoesNotCreateDerivedCompletionState() throws {
        let harness = try makeHarness()
        let item = appendYouTubeItem(to: harness.store)
        item.progressUpdatedAt = .distantPast

        harness.store.saveProgress(
            for: item,
            position: item.duration - 0.5,
            duration: item.duration,
            force: true
        )

        XCTAssertFalse(item.isPlayed)
        let savedPosition = item.playbackPosition
        harness.store.markPlayed(item)
        XCTAssertTrue(item.isPlayed)
        XCTAssertEqual(item.playbackPosition, savedPosition)
    }

    func testRefreshObservesChangesSavedByAnotherModelContext() throws {
        let harness = try makeHarness()
        let externalContext = ModelContext(harness.container)
        let externalItem = QueueItem(
            originalURL: URL(string: "https://podcasts.example/external")!,
            title: "External episode",
            source: .podcast,
            status: .ready,
            sortRank: 1_000
        )
        externalContext.insert(externalItem)
        try externalContext.save()

        XCTAssertTrue(harness.store.items.isEmpty)
        harness.store.refresh()

        XCTAssertEqual(harness.store.items.map(\.id), [externalItem.id])
        XCTAssertEqual(harness.store.items.first?.title, "External episode")
    }

    func testFirstAndNextUnplayedSkipPlayedAndUnavailableItems() throws {
        let harness = try makeHarness()
        let played = appendItem(to: harness.store, ordinal: 1)
        let unavailable = appendItem(to: harness.store, ordinal: 2)
        let ready = appendItem(to: harness.store, ordinal: 3)
        let after = appendItem(to: harness.store, ordinal: 4)

        harness.store.markPlayed(played)
        harness.store.markUnavailable(unavailable, reason: "Gone")

        XCTAssertEqual(harness.store.firstUnplayed()?.id, ready.id)
        XCTAssertEqual(harness.store.nextUnplayed(after: ready)?.id, after.id)
        XCTAssertNil(harness.store.nextUnplayed(after: after))
    }

    func testStartedVideoRemainsInPlaceAndEligibleUntilMarkedPlayed() throws {
        let harness = try makeHarness()
        let current = appendItem(to: harness.store, ordinal: 1)
        let startedVideo = appendYouTubeItem(to: harness.store)
        let after = appendItem(to: harness.store, ordinal: 3)
        let originalOrder = harness.store.items.map(\.id)

        harness.store.recordPlaybackStarted(for: startedVideo)

        XCTAssertFalse(startedVideo.isPlayed)
        XCTAssertFalse(startedVideo.isInPlayedSection)
        XCTAssertEqual(harness.store.items.map(\.id), originalOrder)
        XCTAssertEqual(harness.store.firstUnplayed()?.id, current.id)
        XCTAssertEqual(harness.store.nextUnplayed(after: current)?.id, startedVideo.id)
        harness.store.markPlayed(current)
        XCTAssertEqual(harness.store.firstUnplayed()?.id, startedVideo.id)
        XCTAssertEqual(harness.store.nextUnplayed(after: startedVideo)?.id, after.id)
    }

    func testYouTubeMetadataAtOrOverThirtyDaysIsPurgedAfterTransientRefreshFailure() async throws {
        for ageInDays in [30.0, 31.0] {
            let harness = try makeHarness(
                providers: [TransientFailingYouTubeProvider()]
            )
            let item = appendYouTubeItem(to: harness.store)
            let now = Date()
            item.metadataFetchedAt = now.addingTimeInterval(
                -ageInDays * 24 * 60 * 60
            )

            await harness.store.refreshExpiredYouTubeMetadata(now: now)

            XCTAssertEqual(item.title, "YouTube video")
            XCTAssertEqual(item.subtitle, "")
            XCTAssertNil(item.artworkURLString)
            XCTAssertEqual(item.duration, 0)
            XCTAssertNil(item.metadataFetchedAt)
            XCTAssertFalse(item.youtubeMadeForKids)
            XCTAssertFalse(item.youtubeEmbeddable)
            XCTAssertEqual(item.status, .unavailable)
            XCTAssertEqual(
                item.unavailableReason,
                "YouTube metadata expired and could not be refreshed."
            )

            harness.store.lastErrorMessage = nil
            await harness.store.refreshExpiredYouTubeMetadata(now: now)
            XCTAssertNil(
                harness.store.lastErrorMessage,
                "Purged unavailable metadata should wait for manual retry."
            )
        }
    }

    func testYouTubeMetadataUnderThirtyDaysIsPreservedAfterTransientRefreshFailure() async throws {
        let harness = try makeHarness(
            providers: [TransientFailingYouTubeProvider()]
        )
        let item = appendYouTubeItem(to: harness.store)
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-29.5 * 24 * 60 * 60)
        item.metadataFetchedAt = fetchedAt

        await harness.store.refreshExpiredYouTubeMetadata(now: now)

        XCTAssertEqual(item.title, "API title")
        XCTAssertEqual(item.subtitle, "API channel")
        XCTAssertEqual(
            item.artworkURLString,
            "https://images.example.com/video.jpg"
        )
        XCTAssertEqual(item.duration, 420)
        XCTAssertEqual(item.metadataFetchedAt, fetchedAt)
        XCTAssertTrue(item.youtubeMadeForKids)
        XCTAssertTrue(item.youtubeEmbeddable)
        XCTAssertEqual(item.status, .ready)
        XCTAssertNil(item.unavailableReason)
        XCTAssertTrue(
            harness.store.lastErrorMessage?.contains("Temporary failure") == true
        )
    }

    func testYouTubeTerminalRefreshFailureMarksItemUnavailableBeforeExpiry() async throws {
        let harness = try makeHarness(
            providers: [TerminalFailingYouTubeProvider()]
        )
        let item = appendYouTubeItem(to: harness.store)
        let now = Date()
        item.metadataFetchedAt = now.addingTimeInterval(-29.5 * 24 * 60 * 60)

        await harness.store.refreshExpiredYouTubeMetadata(now: now)

        XCTAssertEqual(item.status, .unavailable)
        XCTAssertEqual(
            item.unavailableReason,
            ProviderResolutionError.youtubeVideoNotEmbeddable(
                "dQw4w9WgXcQ"
            ).localizedDescription
        )
        XCTAssertEqual(item.title, "API title")
        XCTAssertNotNil(item.metadataFetchedAt)

        harness.store.lastErrorMessage = nil
        await harness.store.refreshExpiredYouTubeMetadata(now: now)
        XCTAssertNil(
            harness.store.lastErrorMessage,
            "Terminally unavailable metadata should not retry automatically."
        )

        await harness.store.refreshExpiredYouTubeMetadata(
            now: now.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(item.title, "YouTube video")
        XCTAssertNil(item.metadataFetchedAt)
        XCTAssertNil(harness.store.lastErrorMessage)
    }
}

@MainActor
private extension QueueStoreTests {
    struct Harness {
        let container: ModelContainer
        let store: QueueStore
    }

    func makeHarness(
        providers: [any MediaProvider] = []
    ) throws -> Harness {
        let persistence = try PersistenceController.makeContainer(inMemory: true)
        return Harness(
            container: persistence.container,
            store: QueueStore(
                context: persistence.container.mainContext,
                providers: ProviderRegistry(providers: providers)
            )
        )
    }

    @discardableResult
    func appendItem(
        to store: QueueStore,
        ordinal: Int,
        duration: TimeInterval = 300
    ) -> QueueItem {
        store.appendResolvedForTesting(
            ProviderResolvedItem(
                originalURL: URL(
                    string: "https://podcasts.example/episodes/\(ordinal)"
                )!,
                canonicalURL: URL(
                    string: "https://podcasts.example/episodes/\(ordinal)"
                )!,
                title: "Episode \(ordinal)",
                creatorName: "Test Show",
                artworkURL: nil,
                duration: duration,
                publishedAt: nil,
                source: .podcast,
                playback: .remoteAudio(
                    URL(
                        string: "https://cdn.example.com/episodes/\(ordinal).mp3"
                    )!
                ),
                isMadeForKids: false
            )
        )
    }

    @discardableResult
    func appendYouTubeItem(to store: QueueStore) -> QueueItem {
        store.appendResolvedForTesting(
            ProviderResolvedItem(
                originalURL: URL(
                    string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                )!,
                canonicalURL: URL(
                    string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                )!,
                title: "API title",
                creatorName: "API channel",
                artworkURL: URL(
                    string: "https://images.example.com/video.jpg"
                ),
                duration: 420,
                publishedAt: nil,
                source: .youtube,
                playback: .youtubeVideoID("dQw4w9WgXcQ"),
                isMadeForKids: true
            )
        )
    }
}

private struct QueueStubProvider: MediaProvider {
    let source: ProviderSource
    let acceptedHost: String

    func canResolve(_ url: URL) -> Bool {
        if source == .socialVideo {
            return SocialVideoURLParser.isSupported(url)
        }
        return url.host == acceptedHost
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        let slug = url.lastPathComponent
        switch source {
        case .podcast:
            return ProviderResolvedItem(
                originalURL: url,
                canonicalURL: url,
                title: "Resolved \(slug)",
                creatorName: "Stub Podcast",
                artworkURL: URL(
                    string: "https://images.example.com/\(slug).jpg"
                ),
                duration: 1_234,
                publishedAt: nil,
                source: .podcast,
                playback: .remoteAudio(
                    URL(string: "https://cdn.example.com/\(slug).mp3")!
                ),
                isMadeForKids: false
            )
        case .socialVideo:
            return ProviderResolvedItem(
                originalURL: url,
                canonicalURL: url,
                title: "Resolved \(slug)",
                creatorName: "@stub",
                artworkURL: nil,
                duration: nil,
                publishedAt: nil,
                source: .socialVideo,
                playback: .remoteVideo(
                    URL(string: "https://cdn.example.com/\(slug).mp4")!,
                    expiresAt: Date().addingTimeInterval(240)
                ),
                isMadeForKids: false
            )
        case .youtube:
            return ProviderResolvedItem(
                originalURL: url,
                canonicalURL: url,
                title: "Resolved \(slug)",
                creatorName: "Stub Channel",
                artworkURL: nil,
                duration: 432,
                publishedAt: nil,
                source: .youtube,
                playback: .youtubeVideoID("dQw4w9WgXcQ"),
                isMadeForKids: false
            )
        }
    }
}

private actor QueueResolutionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resolutionWaiter: CheckedContinuation<Void, Never>?

    func suspendResolution() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resolutionWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        resolutionWaiter?.resume()
        resolutionWaiter = nil
    }
}

private struct DelayedQueueProvider: MediaProvider {
    let source = ProviderSource.podcast
    let gate: QueueResolutionGate

    func canResolve(_ url: URL) -> Bool {
        url.host == "podcasts.example"
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        await gate.suspendResolution()
        return ProviderResolvedItem(
            originalURL: url,
            canonicalURL: url,
            title: "Slow episode",
            creatorName: "Test Show",
            artworkURL: nil,
            duration: 600,
            publishedAt: nil,
            source: .podcast,
            playback: .remoteAudio(
                URL(string: "https://cdn.example.com/slow.mp3")!
            ),
            isMadeForKids: false
        )
    }
}

private struct TransientFailingYouTubeProvider: MediaProvider {
    let source = ProviderSource.youtube

    func canResolve(_ url: URL) -> Bool {
        YouTubeURLParser.isYouTubeURL(url)
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        throw ProviderResolutionError.network("Temporary failure")
    }
}

private struct TerminalFailingYouTubeProvider: MediaProvider {
    let source = ProviderSource.youtube

    func canResolve(_ url: URL) -> Bool {
        YouTubeURLParser.isYouTubeURL(url)
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        throw ProviderResolutionError.youtubeVideoNotEmbeddable(
            "dQw4w9WgXcQ"
        )
    }
}
