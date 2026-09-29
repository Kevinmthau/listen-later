import AVFoundation
import Foundation
import SwiftData
import XCTest
@testable import ListenLater

@MainActor
final class PlaybackCoordinatorPodcastEngineTests: XCTestCase {
    func testPlayOrPauseResumesFirstPodcastAtItsSavedPositionAndRate() throws {
        let harness = try makeHarness()
        let item = appendPodcast(
            to: harness.queue,
            ordinal: 1,
            duration: 1_800,
            position: 91.25,
            rate: 1.5
        )

        harness.coordinator.playOrPause()

        XCTAssertEqual(harness.coordinator.currentItemID, item.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.coordinator.position, 91.25, accuracy: 0.001)
        XCTAssertEqual(harness.coordinator.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(harness.engine.loads.count, 1)
        XCTAssertEqual(
            harness.engine.loads.first?.url,
            URL(string: "https://cdn.example.com/episodes/1.mp3")
        )
        XCTAssertEqual(harness.engine.loads.first?.position ?? -1, 91.25, accuracy: 0.001)
        XCTAssertEqual(harness.engine.loads.first?.rate ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(harness.engine.playCallCount, 1)

        harness.coordinator.pause()
        harness.coordinator.playOrPause()

        XCTAssertEqual(harness.engine.loads.count, 1, "Resuming a paused item must not reload it.")
        XCTAssertEqual(harness.engine.playCallCount, 2)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testPodcastEndMarksCurrentItemPlayedAndAdvancesToNextPodcast() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)

        harness.coordinator.playOrPause()
        harness.engine.emit(.ended)

        XCTAssertTrue(first.isPlayed)
        XCTAssertEqual(first.playbackPosition, first.duration, accuracy: 0.001)
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.map(\.url), [
            URL(string: "https://cdn.example.com/episodes/1.mp3")!,
            URL(string: "https://cdn.example.com/episodes/2.mp3")!,
        ])
        XCTAssertEqual(harness.engine.playCallCount, 2)
    }

    func testSocialVideoUsesNativePlayerAndPersistsVideoProgress() throws {
        let harness = try makeHarness()
        let item = appendSocialVideo(to: harness.queue, ordinal: 1)

        harness.coordinator.start(item)

        XCTAssertEqual(harness.coordinator.currentItemID, item.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(
            harness.engine.loads.last?.url,
            URL(string: "https://cdn.example.com/social/1.mp4")
        )
        XCTAssertFalse(item.isInPlayedSection)
        XCTAssertNotNil(item.lastPlayedAt)
        XCTAssertFalse(item.isPlayed)

        item.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 45, duration: 120))
        XCTAssertEqual(item.playbackPosition, 45)
        XCTAssertEqual(item.duration, 120)
        XCTAssertFalse(item.isPlayed)

        harness.engine.emit(.ended)
        XCTAssertTrue(item.isPlayed)
        XCTAssertEqual(item.playbackPosition, 120)
    }

    func testReorderingUpNextWhileVideoPlaysStillAdvancesToFirstItem() throws {
        let harness = try makeHarness()
        let video = appendSocialVideo(to: harness.queue, ordinal: 1)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        let third = appendPodcast(to: harness.queue, ordinal: 3, duration: 600)

        harness.coordinator.start(video)
        harness.queue.moveUpNext(from: IndexSet(integer: 2), to: 1)
        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, third.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.last?.url, third.playbackURL)
        XCTAssertEqual(harness.queue.items.map(\.id), [video.id, third.id, second.id])
    }

    func testCompletedPodcastIsNotRevertedByAutomaticAdvanceProgressSave() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)

        harness.coordinator.playOrPause()
        harness.engine.emit(.timeChanged(position: 120, duration: 300))
        harness.engine.emit(.ended)

        let completedFirst = try XCTUnwrap(harness.queue.item(id: first.id))
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertTrue(completedFirst.isPlayed)
        XCTAssertEqual(completedFirst.playbackPosition, 300, accuracy: 0.001)
        XCTAssertEqual(completedFirst.duration, 300, accuracy: 0.001)
    }

    func testPodcastFailureMarksItemUnavailableAndSkipsToNextItem() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)

        harness.coordinator.playOrPause()
        harness.engine.emit(.failed("The media server returned 404."))

        XCTAssertEqual(first.status, .unavailable)
        XCTAssertEqual(first.unavailableReason, "The media server returned 404.")
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.last?.url, second.playbackURL)
        XCTAssertEqual(harness.engine.playCallCount, 2)
    }

    func testLatePodcastEventCannotAffectNewCurrentItem() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)

        harness.coordinator.start(first)
        let firstLoadID = try XCTUnwrap(harness.engine.loads.last?.loadID)
        harness.coordinator.start(second)

        harness.engine.emit(.ended, loadID: firstLoadID)
        harness.engine.emit(.failed("Late failure"), loadID: firstLoadID)

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertFalse(second.isPlayed)
        XCTAssertEqual(second.status, .ready)
        XCTAssertEqual(harness.engine.playCallCount, 2)
    }

    func testSelectingResolvingItemParksPreviousPodcast() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let resolving = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        resolving.status = .resolving

        harness.coordinator.start(first)
        XCTAssertTrue(harness.engine.isPlaying)

        harness.coordinator.start(resolving)

        XCTAssertEqual(harness.coordinator.currentItemID, resolving.id)
        XCTAssertEqual(harness.coordinator.transportState, .loading)
        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertGreaterThanOrEqual(harness.engine.pauseCallCount, 2)
    }

    func testSeekAndPlaybackRateAreSentToEngineAndPersisted() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)

        harness.coordinator.start(item)
        harness.coordinator.seek(to: 123.5)
        harness.coordinator.setPlaybackRate(1.6)

        XCTAssertEqual(harness.engine.seekCalls, [123.5])
        XCTAssertEqual(harness.engine.rateCalls, [1.5])
        XCTAssertEqual(harness.coordinator.position, 123.5, accuracy: 0.001)
        XCTAssertEqual(harness.coordinator.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(item.playbackPosition, 123.5, accuracy: 0.001)
        XCTAssertEqual(item.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertFalse(item.isPlayed)
    }

    func testPausedPodcastAdoptsSyncedProgressAndRate() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 900)
        harness.coordinator.start(item, autoplay: false)

        harness.queue.saveProgress(
            for: item,
            position: 321,
            duration: 900,
            rate: 1.75,
            force: true
        )
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.position, 321)
        XCTAssertEqual(harness.coordinator.duration, 900)
        XCTAssertEqual(harness.coordinator.playbackRate, 1.75)
        XCTAssertEqual(harness.engine.seekCalls.last, 321)
        XCTAssertEqual(harness.engine.rateCalls.last, 1.75)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
    }

    func testPausedYouTubeAdoptsSyncedProgressAndRate() throws {
        let harness = try makeHarness()
        let item = appendYouTube(to: harness.queue, ordinal: 1)
        harness.coordinator.start(item, autoplay: false)
        harness.coordinator.pause()

        harness.queue.saveProgress(
            for: item,
            position: 137,
            duration: 240,
            rate: 1.5,
            force: true
        )
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.position, 137)
        XCTAssertEqual(harness.coordinator.duration, 240)
        XCTAssertEqual(harness.coordinator.playbackRate, 1.5)
        XCTAssertEqual(harness.youtubePlayer.currentTime, 137)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
    }

    func testUnavailablePausedItemAdvancesDuringQueueReconciliation() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first, autoplay: false)

        harness.queue.markUnavailable(first, reason: "No longer available.")
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.last?.url, second.playbackURL)
    }

    func testUnavailablePlayingItemAdvancesDuringQueueReconciliation() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first)

        harness.queue.markUnavailable(first, reason: "No longer available.")
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.last?.url, second.playbackURL)
    }

    func testExternallyPlayedPausedItemAdvancesDuringQueueReconciliation() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first, autoplay: false)

        harness.queue.markPlayed(first)
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.last?.url, second.playbackURL)
    }

    func testActivePartialPlaybackOverridesSyncedPlayedState() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first)
        first.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 120, duration: 300))

        harness.queue.markPlayed(first)
        harness.coordinator.reconcileQueueState()

        XCTAssertFalse(first.isPlayed)
        XCTAssertFalse(first.isInPlayedSection)
        XCTAssertEqual(first.playbackPosition, 120)
        XCTAssertEqual(harness.coordinator.currentItemID, first.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertNotEqual(harness.coordinator.currentItemID, second.id)
    }

    func testReconcilingWhilePlayingLeavesAgreeingProgressAlone() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        harness.coordinator.start(item)
        item.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 120, duration: 300))
        let savedAt = item.progressUpdatedAt
        harness.engine.emit(.timeChanged(position: 124, duration: 300))

        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(
            item.progressUpdatedAt,
            savedAt,
            "This device's own save coming back must not prompt another."
        )
        XCTAssertEqual(item.playbackPosition, 120)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testReconcilingWhilePlayingReassertsProgressAnotherDeviceChanged() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        harness.coordinator.start(item)
        item.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 120, duration: 300))

        // An older session on another device syncs in.
        harness.queue.saveProgress(for: item, position: 30, force: true)
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(item.playbackPosition, 120)
        XCTAssertEqual(harness.coordinator.position, 120)
        XCTAssertFalse(harness.engine.seekCalls.contains(30))
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testReconcilingWhilePausedDoesNotSeekForThisDevicesOwnSave() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 900)
        harness.coordinator.start(item)
        harness.engine.emit(.timeChanged(position: 200, duration: 900))
        harness.coordinator.pause()
        let seekCount = harness.engine.seekCalls.count

        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.engine.seekCalls.count, seekCount)
        XCTAssertEqual(harness.coordinator.position, 200)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
    }

    func testNearEndProgressDoesNotMarkPlayedOrAdvanceBeforeActivePlayerEnds() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        let originalOrder = harness.queue.items.map(\.id)
        harness.coordinator.start(first)
        first.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 299, duration: 300))
        XCTAssertFalse(first.isPlayed)
        XCTAssertFalse(first.isInPlayedSection)
        XCTAssertEqual(
            harness.queue.items.filter { !$0.isInPlayedSection }.map(\.id),
            originalOrder
        )

        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.currentItemID, first.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertTrue(harness.engine.isPlaying)

        harness.engine.emit(.ended)

        XCTAssertTrue(first.isPlayed)
        XCTAssertTrue(first.isInPlayedSection)
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
    }

    func testPlayNextKeepsPartialItemUnplayedAndMovesItToTheEndOfUpNext() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first)
        first.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 120, duration: 300))

        harness.coordinator.playNext()

        XCTAssertFalse(first.isPlayed)
        XCTAssertFalse(first.isInPlayedSection)
        XCTAssertEqual(first.playbackPosition, 120)
        XCTAssertEqual(
            harness.queue.items.filter { !$0.isInPlayedSection }.map(\.id),
            [second.id, first.id],
            "Up Next lists items in the order they will play."
        )
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)

        harness.engine.emit(.ended)

        XCTAssertTrue(second.isPlayed)
        XCTAssertEqual(harness.coordinator.currentItemID, first.id)
        XCTAssertEqual(harness.coordinator.position, 120)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testPlayNextOnOnlyItemStopsWithoutMarkingItPlayed() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        harness.coordinator.start(item)
        item.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 120, duration: 300))

        harness.coordinator.playNext()

        XCTAssertFalse(item.isPlayed)
        XCTAssertFalse(item.isInPlayedSection)
        XCTAssertEqual(item.playbackPosition, 120)
        XCTAssertNil(harness.coordinator.currentItemID)
        XCTAssertEqual(harness.coordinator.transportState, .idle)
        XCTAssertEqual(harness.coordinator.notice, "This item remains in Up Next.")
        XCTAssertEqual(harness.queue.firstUnplayed()?.id, item.id)
    }

    func testQueueRefreshDeletionStopsCurrentPlayback() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        harness.coordinator.start(item)
        XCTAssertTrue(harness.engine.isPlaying)

        harness.queue.delete(item)
        harness.coordinator.reconcileQueueState()

        XCTAssertNil(harness.coordinator.currentItemID)
        XCTAssertEqual(harness.coordinator.transportState, .idle)
        XCTAssertFalse(harness.engine.isPlaying)
    }

    func testYouTubeItemWaitsForForegroundBeforeLoading() throws {
        let harness = try makeHarness()
        let item = appendYouTube(to: harness.queue, ordinal: 1)

        harness.coordinator.sceneWillResignActive()
        harness.coordinator.playOrPause()

        XCTAssertEqual(harness.coordinator.currentItemID, item.id)
        XCTAssertEqual(harness.coordinator.transportState, .waitingForForeground)
        XCTAssertEqual(
            harness.coordinator.notice,
            "Open MushRadio to play this YouTube video."
        )
        XCTAssertNil(
            harness.youtubePlayer.videoID,
            "The embedded YouTube player must not be loaded for background playback."
        )
        XCTAssertFalse(harness.youtubePlayer.isPlaying)

        harness.coordinator.sceneDidBecomeActive()

        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(harness.youtubePlayer.videoID, "video00001")
        XCTAssertEqual(
            harness.coordinator.notice,
            "Tap Play to continue this YouTube video."
        )
    }

    func testReplayingPlayedYouTubeClearsPlayedStateAndProgress() throws {
        let harness = try makeHarness()
        let item = appendYouTube(to: harness.queue, ordinal: 1)
        harness.queue.saveProgress(
            for: item,
            position: 120,
            duration: 240,
            force: true
        )
        harness.queue.markPlayed(item)

        harness.coordinator.start(item, autoplay: false)

        XCTAssertFalse(item.isPlayed)
        XCTAssertEqual(item.playbackPosition, 0)
        XCTAssertEqual(harness.coordinator.position, 0)
        XCTAssertEqual(harness.coordinator.currentItemID, item.id)
    }

    func testLoadingYouTubeDoesNotMoveItToPlayedBeforePlaybackBegins() throws {
        let harness = try makeHarness()
        let item = appendYouTube(to: harness.queue, ordinal: 1)

        harness.coordinator.start(item)

        XCTAssertFalse(item.isInPlayedSection)
        XCTAssertNil(item.lastPlayedAt)
        XCTAssertEqual(harness.coordinator.transportState, .loading)
    }

    func testPodcastWatchdogStallRemainsRetryable() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first)

        harness.engine.emit(.stalled("Playback timed out."))

        XCTAssertEqual(first.status, .ready)
        XCTAssertEqual(harness.coordinator.currentItemID, first.id)
        XCTAssertEqual(harness.coordinator.transportState, .needsUserAction)
        XCTAssertEqual(harness.engine.loads.count, 1)
        XCTAssertNotEqual(harness.coordinator.currentItemID, second.id)

        harness.coordinator.play()

        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.engine.loads.count, 2)
        XCTAssertEqual(harness.engine.loads.last?.url, first.playbackURL)
    }

    func testYouTubePlayerRejectsStaleLoadAndVideoEvents() {
        let player = YouTubePlayerModel()
        let firstLoadID = UUID()
        let secondLoadID = UUID()
        var delivered: [YouTubePlayerEvent] = []
        player.eventHandler = { _, event in delivered.append(event) }

        player.load(
            videoID: "video00001",
            position: 0,
            autoplay: true,
            playbackRate: 1,
            loadID: firstLoadID
        )
        player.load(
            videoID: "video00002",
            position: 0,
            autoplay: true,
            playbackRate: 1.5,
            loadID: secondLoadID
        )

        player.receive(
            .ended,
            loadID: firstLoadID,
            videoID: "video00001"
        )
        player.receive(
            .ended,
            loadID: secondLoadID,
            videoID: "video00001"
        )
        XCTAssertTrue(delivered.isEmpty)

        player.receive(
            .playing,
            loadID: secondLoadID,
            videoID: "video00002"
        )
        player.receive(
            .failed(code: 100),
            loadID: secondLoadID,
            videoID: "video00002"
        )
        XCTAssertEqual(delivered, [.playing, .failed(code: 100)])
    }

    func testStartingAnItemMovesItToTheTopOfUpNext() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        let third = appendPodcast(to: harness.queue, ordinal: 3, duration: 300)

        harness.coordinator.start(third)

        XCTAssertEqual(
            harness.queue.items.map(\.id),
            [third.id, first.id, second.id]
        )

        harness.engine.emit(.ended)

        XCTAssertTrue(third.isPlayed)
        XCTAssertEqual(
            harness.coordinator.currentItemID,
            first.id,
            "After the chosen item, playback continues from the top of Up Next."
        )
    }

    func testAutomaticAdvanceDoesNotRewriteRanks() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        harness.coordinator.start(first)
        let ranks = harness.queue.items.map(\.sortRank)

        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.queue.items.map(\.sortRank), ranks)
    }

    func testSkippingTwiceCyclesThroughUpNextInListOrder() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        let third = appendPodcast(to: harness.queue, ordinal: 3, duration: 300)
        harness.coordinator.start(first)

        harness.coordinator.playNext()
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        harness.coordinator.playNext()
        XCTAssertEqual(harness.coordinator.currentItemID, third.id)

        XCTAssertEqual(
            harness.queue.items.map(\.id),
            [third.id, first.id, second.id]
        )
    }

    func testBackgroundAdvanceSkipsVideosAndLeavesThemInUpNext() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        let youtube = appendYouTube(to: harness.queue, ordinal: 3)
        let second = appendPodcast(to: harness.queue, ordinal: 4, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.sceneWillResignActive()

        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(
            harness.queue.items.filter { !$0.isInPlayedSection }.map(\.id),
            [second.id, video.id, youtube.id]
        )
        XCTAssertFalse(video.isPlayed)
        XCTAssertNil(video.lastPlayedAt)
    }

    func testBackgroundAdvanceLeavesAVideoReadyWhenNoAudioRemains() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        harness.coordinator.start(first)
        harness.coordinator.sceneWillResignActive()

        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(harness.engine.playCallCount, 1)
        XCTAssertEqual(harness.engine.loads.last?.url, video.playbackURL)
        XCTAssertEqual(
            harness.coordinator.notice,
            "Paused so you can watch this video."
        )
        XCTAssertFalse(video.isPlayed)
    }

    func testBackgroundAdvancePlaysVideosWhenTheyDontWaitForTheScreen() throws {
        let harness = try makeHarness(videosWaitForScreen: false)
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        let second = appendPodcast(to: harness.queue, ordinal: 3, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.sceneWillResignActive()

        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
        XCTAssertNotEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testEndOfItemSleepTimerInTheBackgroundKeepsQueueOrder() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        let second = appendPodcast(to: harness.queue, ordinal: 3, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.sceneWillResignActive()
        harness.coordinator.setSleepTimerAtEndOfItem()

        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(
            harness.queue.items.filter { !$0.isInPlayedSection }.map(\.id),
            [video.id, second.id],
            "Nothing autoplays, so the later podcast doesn't jump the video."
        )
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")
    }

    func testRemoteNextInTheBackgroundPrefersAudio() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        let second = appendPodcast(to: harness.queue, ordinal: 3, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.sceneWillResignActive()

        harness.coordinator.playNext()

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertFalse(video.isPlayed)
        XCTAssertFalse(first.isPlayed)
    }

    func testForegroundAdvanceStillPlaysVideosInOrder() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        harness.coordinator.start(first)

        harness.engine.emit(.ended)

        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testReturningToTheAppAdvancesWithTheOnScreenRules() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        let second = appendPodcast(to: harness.queue, ordinal: 3, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.pause()
        harness.coordinator.sceneWillResignActive()

        // Another device finishes the podcast while this one is away.
        harness.queue.markPlayed(first)
        harness.coordinator.sceneDidBecomeActive()

        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
        XCTAssertEqual(
            harness.queue.items.filter { !$0.isInPlayedSection }.map(\.id),
            [video.id, second.id]
        )
    }

    func testAYouTubeVideoWaitingForTheScreenLoadsAtItsSyncedPosition() throws {
        let harness = try makeHarness()
        let item = appendYouTube(to: harness.queue, ordinal: 1)
        harness.coordinator.sceneWillResignActive()
        harness.coordinator.playOrPause()
        XCTAssertEqual(harness.coordinator.transportState, .waitingForForeground)

        // Progress saved on another device while this one was away.
        harness.queue.saveProgress(
            for: item,
            position: 1_200,
            duration: 2_400,
            rate: 1.5,
            force: true
        )
        harness.coordinator.sceneDidBecomeActive()

        XCTAssertEqual(harness.youtubePlayer.videoID, "video00001")
        XCTAssertEqual(harness.youtubePlayer.currentTime, 1_200)
        XCTAssertEqual(harness.coordinator.playbackRate, 1.5)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
    }

    func testAYouTubeVideoFinishedElsewhereIsNotLoadedOnReturn() throws {
        let harness = try makeHarness()
        let youtube = appendYouTube(to: harness.queue, ordinal: 1)
        let podcast = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        harness.coordinator.sceneWillResignActive()
        // Chosen by hand: in the background, Play itself would pick audio.
        harness.coordinator.start(youtube)
        XCTAssertEqual(harness.coordinator.transportState, .waitingForForeground)

        harness.queue.markPlayed(youtube)
        harness.coordinator.sceneDidBecomeActive()

        XCTAssertNil(harness.youtubePlayer.videoID)
        XCTAssertEqual(harness.coordinator.currentItemID, podcast.id)
    }

    func testNextSocialVideoLinkIsRefreshedBeforeItsTurn() async throws {
        let harness = try makeHarness(providers: [RefreshingSocialVideoProvider()])
        let podcast = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let video = appendSocialVideo(to: harness.queue, ordinal: 2)
        video.playbackURLExpiresAt = .distantPast
        harness.coordinator.start(podcast)
        podcast.progressUpdatedAt = .distantPast

        harness.engine.emit(.timeChanged(position: 100, duration: 300))
        XCTAssertTrue(
            video.playbackURLNeedsRefresh(),
            "Nothing is fetched while the current item has minutes left."
        )

        harness.engine.emit(.timeChanged(position: 260, duration: 300))
        let deadline = Date().addingTimeInterval(2)
        while video.playbackURLNeedsRefresh(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(video.playbackURLNeedsRefresh())
        XCTAssertEqual(video.status, .ready)
        XCTAssertEqual(
            video.playbackURL,
            URL(string: "https://cdn.example.com/refreshed/2.mp4")
        )
        XCTAssertEqual(harness.coordinator.currentItemID, podcast.id)

        // The refreshed link can expire again, e.g. during a long pause.
        video.playbackURLExpiresAt = .distantPast
        harness.engine.emit(.timeChanged(position: 270, duration: 300))
        let secondDeadline = Date().addingTimeInterval(2)
        while video.playbackURLNeedsRefresh(), Date() < secondDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(
            video.playbackURLNeedsRefresh(),
            "A link that expired again is fetched again."
        )
    }

    func testPausingFromTheFullScreenPlayerIsAPauseNotAStall() throws {
        let harness = try makeHarness()
        let video = appendSocialVideo(to: harness.queue, ordinal: 1)
        harness.coordinator.start(video)
        XCTAssertEqual(harness.coordinator.transportState, .playing)

        harness.engine.emit(.pausedExternally)

        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertFalse(harness.coordinator.isBuffering)
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)

        harness.engine.emit(.resumedExternally)

        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
    }

    func testAVideoInPictureInPictureCountsAsOnScreen() throws {
        let harness = try makeHarness()
        let first = appendSocialVideo(to: harness.queue, ordinal: 1)
        let second = appendSocialVideo(to: harness.queue, ordinal: 2)
        appendPodcast(to: harness.queue, ordinal: 3, duration: 300)
        harness.coordinator.start(first)
        harness.coordinator.sceneWillResignActive()
        NotificationCenter.default.post(name: .pictureInPictureDidStart, object: nil)
        defer {
            NotificationCenter.default.post(name: .pictureInPictureDidStop, object: nil)
        }
        // The observer hops to the main actor; let it run.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        harness.engine.emit(.ended)

        XCTAssertEqual(
            harness.coordinator.currentItemID,
            second.id,
            "The next video plays on in Picture in Picture instead of being skipped."
        )
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testBufferingEventsDriveTheWaitingState() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)

        harness.coordinator.start(item)
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)
        XCTAssertEqual(harness.coordinator.activity, .playing)

        harness.engine.emit(.bufferingChanged(true))
        XCTAssertTrue(harness.coordinator.isBuffering)
        XCTAssertTrue(harness.coordinator.isWaitingForMedia)
        XCTAssertEqual(harness.coordinator.activity, .buffering)
        XCTAssertTrue(
            harness.coordinator.activity.pausesOnTap,
            "Buffering is still playing, so Play is a Pause button."
        )

        harness.engine.emit(.bufferingChanged(false))
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)

        harness.engine.emit(.bufferingChanged(true))
        harness.coordinator.pause()
        XCTAssertFalse(harness.coordinator.isBuffering)
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)
        XCTAssertEqual(harness.coordinator.activity, .paused)
        XCTAssertFalse(harness.coordinator.activity.pausesOnTap)

        harness.engine.emit(.bufferingChanged(true))
        XCTAssertFalse(
            harness.coordinator.isBuffering,
            "A paused item is not waiting for media."
        )
    }

    func testResolvingItemShowsTheWaitingState() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        item.status = .resolving

        harness.coordinator.start(item)

        XCTAssertEqual(harness.coordinator.transportState, .loading)
        XCTAssertTrue(harness.coordinator.isWaitingForMedia)
        XCTAssertEqual(harness.coordinator.activity, .resolving)
        XCTAssertEqual(harness.coordinator.activity.rowStatus, "Fetching details")
    }

    func testNextIsAvailableOnlyWhenAnotherItemCanPlay() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        harness.coordinator.start(first)
        XCTAssertFalse(harness.coordinator.hasNextItem)

        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        XCTAssertTrue(harness.coordinator.hasNextItem)

        harness.queue.markUnavailable(second, reason: "Gone")
        XCTAssertFalse(harness.coordinator.hasNextItem)
    }

    func testSleepTimerAtEndOfItemLeavesTheNextItemPaused() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.setSleepTimerAtEndOfItem()

        harness.engine.emit(.ended)

        XCTAssertTrue(first.isPlayed)
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(harness.engine.playCallCount, 1)
        XCTAssertEqual(harness.engine.loads.last?.url, second.playbackURL)
        XCTAssertEqual(harness.coordinator.sleepTimer, .off)
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")
    }

    func testSleepTimerHoldSurvivesAFailureOfTheNextItem() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        let third = appendPodcast(to: harness.queue, ordinal: 3, duration: 300)
        harness.coordinator.start(first)
        harness.coordinator.setSleepTimerAtEndOfItem()
        harness.engine.emit(.ended)
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)

        harness.engine.emit(.failed("The episode is gone."))

        XCTAssertEqual(harness.coordinator.currentItemID, third.id)
        XCTAssertEqual(
            harness.coordinator.transportState,
            .paused,
            "A failure after the timer fired must not start playback."
        )
        XCTAssertEqual(harness.engine.playCallCount, 1)
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")

        harness.coordinator.play()
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testResumingAVideoWithAnExpiredLinkRefreshesItFirst() throws {
        let harness = try makeHarness()
        let video = appendSocialVideo(to: harness.queue, ordinal: 1)
        harness.coordinator.start(video)
        harness.coordinator.pause()
        let plays = harness.engine.playCallCount
        video.playbackURLExpiresAt = .distantPast

        harness.coordinator.play()

        XCTAssertEqual(harness.engine.playCallCount, plays)
        XCTAssertEqual(harness.coordinator.transportState, .loading)
        XCTAssertEqual(harness.coordinator.notice, "Refreshing the video link…")
    }

    func testPlayingAVideoThatIsAlreadyPlayingKeepsItsLink() throws {
        let harness = try makeHarness()
        let video = appendSocialVideo(to: harness.queue, ordinal: 1)
        harness.coordinator.start(video)
        // Close to expiring, but the player already has the media open.
        video.playbackURLExpiresAt = Date().addingTimeInterval(10)

        harness.coordinator.play()

        XCTAssertEqual(harness.engine.loads.count, 1)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertEqual(video.status, .ready)
    }

    func testAFailedLinkRefreshKeepsTheVideoToTryAgain() async throws {
        let harness = try makeHarness()
        let video = appendSocialVideo(to: harness.queue, ordinal: 1)
        appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        harness.coordinator.start(video)
        harness.coordinator.pause()
        video.playbackURLExpiresAt = .distantPast

        // The test registry has no providers, so the refresh fails with an
        // error about the request, not the video, as it would offline.
        harness.coordinator.play()
        try await waitUntil { harness.coordinator.transportState == .needsUserAction }

        XCTAssertEqual(video.status, .ready)
        XCTAssertEqual(harness.coordinator.currentItemID, video.id)
        XCTAssertEqual(
            harness.coordinator.notice,
            "Couldn’t refresh the video link. Tap Play to try again."
        )
    }

    func testSleepTimerHoldSurvivesTheHeldItemBeingFinishedElsewhere() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 300)
        let third = appendPodcast(to: harness.queue, ordinal: 3, duration: 300)
        harness.coordinator.start(first)
        harness.coordinator.setSleepTimerAtEndOfItem()
        harness.engine.emit(.ended)
        XCTAssertEqual(harness.coordinator.currentItemID, second.id)

        harness.queue.markPlayed(second)
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.currentItemID, third.id)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(harness.engine.playCallCount, 1)
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")
    }

    func testTimedSleepTimerHoldsPlaybackUntilSomethingIsPlayed() async throws {
        let harness = try makeHarness(sleepTimerDelay: { _ in })
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 600)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        harness.coordinator.start(first)
        harness.coordinator.setSleepTimer(minutes: 15)
        try await waitUntil { harness.coordinator.transportState == .paused }

        harness.queue.markUnavailable(first, reason: "Gone")
        harness.coordinator.reconcileQueueState()

        XCTAssertEqual(harness.coordinator.currentItemID, second.id)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(harness.engine.playCallCount, 1)
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")

        harness.coordinator.play()
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testSleepTimerAtEndOfLastItemFinishesTheQueue() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        harness.coordinator.start(item)
        harness.coordinator.setSleepTimerAtEndOfItem()

        harness.engine.emit(.ended)

        XCTAssertTrue(item.isPlayed)
        XCTAssertNil(harness.coordinator.currentItemID)
        XCTAssertEqual(harness.coordinator.transportState, .idle)
        XCTAssertEqual(harness.coordinator.sleepTimer, .off)
        XCTAssertEqual(harness.coordinator.notice, "Queue finished.")
    }

    func testTimedSleepTimerPausesPlaybackWhenItFires() async throws {
        let harness = try makeHarness(sleepTimerDelay: { _ in })
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 600)
        harness.coordinator.start(item)
        XCTAssertEqual(harness.coordinator.transportState, .playing)

        harness.coordinator.setSleepTimer(minutes: 15)
        guard case let .until(fireDate) = harness.coordinator.sleepTimer else {
            return XCTFail("Expected a timed sleep timer.")
        }
        XCTAssertEqual(fireDate.timeIntervalSinceNow, 15 * 60, accuracy: 5)

        let deadline = Date().addingTimeInterval(2)
        while harness.coordinator.sleepTimer != .off, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(harness.coordinator.sleepTimer, .off)
        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")
    }

    func testResumingAfterTheSleepTimerClearsItsNotice() async throws {
        let harness = try makeHarness(sleepTimerDelay: { _ in })
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 600)
        harness.coordinator.start(item)
        harness.coordinator.setSleepTimer(minutes: 15)
        let deadline = Date().addingTimeInterval(2)
        while harness.coordinator.transportState != .paused, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")

        harness.coordinator.play()

        XCTAssertEqual(harness.coordinator.transportState, .playing)
        XCTAssertNil(harness.coordinator.notice)
    }

    func testSleepTimerFiringDuringAnInterruptionCancelsItsResume() async throws {
        let harness = try makeHarness(sleepTimerDelay: { _ in })
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 600)
        harness.coordinator.start(item)
        let playsBeforeInterruption = harness.engine.playCallCount

        postInterruption(.began)
        try await waitUntil { harness.coordinator.transportState == .paused }

        harness.coordinator.setSleepTimer(minutes: 15)
        try await waitUntil { harness.coordinator.sleepTimer == .off }
        XCTAssertEqual(harness.coordinator.notice, "Paused by the sleep timer.")

        postInterruption(.ended, options: .shouldResume)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(harness.coordinator.transportState, .paused)
        XCTAssertEqual(
            harness.engine.playCallCount,
            playsBeforeInterruption,
            "The call ending after the timer fired must not restart playback."
        )
    }

    func testCancellingTheSleepTimerKeepsPlaying() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 600)
        harness.coordinator.start(item)

        harness.coordinator.setSleepTimer(minutes: 30)
        harness.coordinator.cancelSleepTimer()

        XCTAssertEqual(harness.coordinator.sleepTimer, .off)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
    }

    func testAPauseRightAfterPlayIsNotMistakenForOutsideControl() async throws {
        let engine = AVPlayerPodcastEngine(playbackWatchdogDelay: {
            try await Task.sleep(for: .seconds(60))
        })
        var events: [PodcastPlaybackEvent] = []
        engine.eventHandler = { _, event in events.append(event) }
        engine.load(
            url: URL(string: "https://192.0.2.1/podcast.mp3")!,
            position: 0,
            rate: 1,
            loadID: UUID()
        )

        // Status changes reach the engine after a hop to the main actor,
        // by which time the app has paused again.
        engine.play()
        engine.pause()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(events.contains(.resumedExternally))
        XCTAssertFalse(events.contains(.pausedExternally))
        engine.tearDown()
    }

    func testPodcastWatchdogFailsAPlaybackThatNeverStarts() async {
        let failure = expectation(description: "Playback watchdog failure")
        let engine = AVPlayerPodcastEngine(playbackWatchdogDelay: {})
        let loadID = UUID()
        engine.eventHandler = { eventLoadID, event in
            guard eventLoadID == loadID,
                  case let .stalled(message) = event,
                  message.contains("did not start or recover")
            else {
                return
            }
            failure.fulfill()
        }

        engine.load(
            url: URL(string: "https://192.0.2.1/podcast.mp3")!,
            position: 0,
            rate: 1,
            loadID: loadID
        )
        engine.play()

        await fulfillment(of: [failure], timeout: 1)
        engine.tearDown()
    }
}

@MainActor
private extension PlaybackCoordinatorPodcastEngineTests {
    struct Harness {
        // Keep the in-memory store alive for the lifetime of each test.
        let container: ModelContainer
        let queue: QueueStore
        let engine: FakePodcastPlaybackEngine
        let youtubePlayer: YouTubePlayerModel
        let coordinator: PlaybackCoordinator
    }

    func postInterruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = []
    ) {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: type.rawValue,
                AVAudioSessionInterruptionOptionKey: options.rawValue,
            ]
        )
    }

    func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for a condition.")
    }

    func makeHarness(
        sleepTimerDelay: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        videosWaitForScreen: Bool = true,
        providers: [any MediaProvider] = []
    ) throws -> Harness {
        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let queue = QueueStore(
            context: persistence.container.mainContext,
            providers: ProviderRegistry(providers: providers)
        )
        let engine = FakePodcastPlaybackEngine()
        let youtubePlayer = YouTubePlayerModel()
        let coordinator = PlaybackCoordinator(
            queue: queue,
            podcastEngine: engine,
            youtubePlayer: youtubePlayer,
            sleepTimerDelay: sleepTimerDelay,
            videosWaitForScreen: { videosWaitForScreen }
        )
        return Harness(
            container: persistence.container,
            queue: queue,
            engine: engine,
            youtubePlayer: youtubePlayer,
            coordinator: coordinator
        )
    }

    @discardableResult
    func appendPodcast(
        to queue: QueueStore,
        ordinal: Int,
        duration: TimeInterval,
        position: TimeInterval = 0,
        rate: Double = 1
    ) -> QueueItem {
        let item = queue.appendResolvedForTesting(
            ProviderResolvedItem(
                originalURL: URL(string: "https://example.com/episodes/\(ordinal)")!,
                canonicalURL: URL(string: "https://example.com/episodes/\(ordinal)")!,
                title: "Episode \(ordinal)",
                creatorName: "Test Show",
                artworkURL: nil,
                duration: duration,
                publishedAt: nil,
                source: .podcast,
                playback: .remoteAudio(
                    URL(string: "https://cdn.example.com/episodes/\(ordinal).mp3")!
                ),
                isMadeForKids: false
            )
        )
        item.progressUpdatedAt = .distantPast
        queue.saveProgress(
            for: item,
            position: position,
            duration: duration,
            rate: rate,
            force: true
        )
        return item
    }

    @discardableResult
    func appendYouTube(to queue: QueueStore, ordinal: Int) -> QueueItem {
        queue.appendResolvedForTesting(
            ProviderResolvedItem(
                originalURL: URL(
                    string: "https://www.youtube.com/watch?v=video\(String(format: "%05d", ordinal))"
                )!,
                canonicalURL: URL(
                    string: "https://www.youtube.com/watch?v=video\(String(format: "%05d", ordinal))"
                )!,
                title: "Video \(ordinal)",
                creatorName: "Test Channel",
                artworkURL: nil,
                duration: 240,
                publishedAt: nil,
                source: .youtube,
                playback: .youtubeVideoID("video\(String(format: "%05d", ordinal))"),
                isMadeForKids: false
            )
        )
    }

    @discardableResult
    func appendSocialVideo(to queue: QueueStore, ordinal: Int) -> QueueItem {
        queue.appendResolvedForTesting(
            ProviderResolvedItem(
                originalURL: URL(
                    string: "https://x.com/example/status/\(ordinal)"
                )!,
                canonicalURL: URL(
                    string: "https://x.com/example/status/\(ordinal)"
                )!,
                title: "X video",
                creatorName: "@example",
                artworkURL: nil,
                duration: nil,
                publishedAt: nil,
                source: .socialVideo,
                playback: .remoteVideo(
                    URL(string: "https://cdn.example.com/social/\(ordinal).mp4")!,
                    expiresAt: Date().addingTimeInterval(240)
                ),
                isMadeForKids: false
            )
        )
    }
}

private struct RefreshingSocialVideoProvider: MediaProvider {
    let source = ProviderSource.socialVideo

    func canResolve(_ url: URL) -> Bool {
        SocialVideoURLParser.isSupported(url)
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        ProviderResolvedItem(
            originalURL: url,
            canonicalURL: url,
            title: "X video",
            creatorName: "@example",
            artworkURL: nil,
            duration: nil,
            publishedAt: nil,
            source: .socialVideo,
            playback: .remoteVideo(
                URL(string: "https://cdn.example.com/refreshed/\(url.lastPathComponent).mp4")!,
                expiresAt: Date().addingTimeInterval(600)
            ),
            isMadeForKids: false
        )
    }
}

@MainActor
private final class FakePodcastPlaybackEngine: PodcastPlaybackEngine {
    struct Load: Equatable {
        let url: URL
        let position: TimeInterval
        let rate: Float
        let loadID: UUID
    }

    var eventHandler: ((UUID, PodcastPlaybackEvent) -> Void)?
    private(set) var isPlaying = false
    private(set) var loads: [Load] = []
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var seekCalls: [TimeInterval] = []
    private(set) var rateCalls: [Float] = []

    func load(
        url: URL,
        position: TimeInterval,
        rate: Float,
        loadID: UUID
    ) {
        loads.append(
            Load(url: url, position: position, rate: rate, loadID: loadID)
        )
        isPlaying = false
    }

    func play() {
        playCallCount += 1
        isPlaying = true
    }

    func pause() {
        pauseCallCount += 1
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        seekCalls.append(time)
    }

    func setRate(_ rate: Float) {
        rateCalls.append(rate)
    }

    func emit(_ event: PodcastPlaybackEvent, loadID: UUID? = nil) {
        switch event {
        case .ended, .stalled, .failed, .pausedExternally:
            isPlaying = false
        case .resumedExternally:
            isPlaying = true
        case .timeChanged, .bufferingChanged:
            break
        }
        guard let loadID = loadID ?? loads.last?.loadID else { return }
        eventHandler?(loadID, event)
    }
}
