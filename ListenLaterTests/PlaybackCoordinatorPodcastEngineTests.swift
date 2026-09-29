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

    func testPlayNextKeepsPartialItemUnplayedAndInItsQueuePosition() throws {
        let harness = try makeHarness()
        let first = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)
        let second = appendPodcast(to: harness.queue, ordinal: 2, duration: 600)
        let originalOrder = harness.queue.items.map(\.id)
        harness.coordinator.start(first)
        first.progressUpdatedAt = .distantPast
        harness.engine.emit(.timeChanged(position: 120, duration: 300))

        harness.coordinator.playNext()

        XCTAssertFalse(first.isPlayed)
        XCTAssertFalse(first.isInPlayedSection)
        XCTAssertEqual(first.playbackPosition, 120)
        XCTAssertEqual(harness.queue.items.map(\.id), originalOrder)
        XCTAssertEqual(
            harness.queue.items.filter { !$0.isInPlayedSection }.map(\.id),
            originalOrder
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

    func testBufferingEventsDriveTheWaitingState() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 300)

        harness.coordinator.start(item)
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)

        harness.engine.emit(.bufferingChanged(true))
        XCTAssertTrue(harness.coordinator.isBuffering)
        XCTAssertTrue(harness.coordinator.isWaitingForMedia)

        harness.engine.emit(.bufferingChanged(false))
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)

        harness.engine.emit(.bufferingChanged(true))
        harness.coordinator.pause()
        XCTAssertFalse(harness.coordinator.isBuffering)
        XCTAssertFalse(harness.coordinator.isWaitingForMedia)

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

    func testCancellingTheSleepTimerKeepsPlaying() throws {
        let harness = try makeHarness()
        let item = appendPodcast(to: harness.queue, ordinal: 1, duration: 600)
        harness.coordinator.start(item)

        harness.coordinator.setSleepTimer(minutes: 30)
        harness.coordinator.cancelSleepTimer()

        XCTAssertEqual(harness.coordinator.sleepTimer, .off)
        XCTAssertEqual(harness.coordinator.transportState, .playing)
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

    func makeHarness(
        sleepTimerDelay: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) throws -> Harness {
        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let queue = QueueStore(
            context: persistence.container.mainContext,
            providers: ProviderRegistry(providers: [])
        )
        let engine = FakePodcastPlaybackEngine()
        let youtubePlayer = YouTubePlayerModel()
        let coordinator = PlaybackCoordinator(
            queue: queue,
            podcastEngine: engine,
            youtubePlayer: youtubePlayer,
            sleepTimerDelay: sleepTimerDelay
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
        case .ended, .stalled, .failed:
            isPlaying = false
        case .timeChanged, .bufferingChanged:
            break
        }
        guard let loadID = loadID ?? loads.last?.loadID else { return }
        eventHandler?(loadID, event)
    }
}
