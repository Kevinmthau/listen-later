import AVFoundation
import Foundation
import SwiftData
import XCTest

@MainActor
final class MacPlaybackCoordinatorTests: XCTestCase {
    func testAutomaticPlaybackSkipsMissingLocalBytesWithoutMutatingStatus() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PlaybackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: source)
        let library = LocalMediaLibrary(root: root.appending(path: "Owned")) { _ in
            LocalMediaInspection(
                title: "First",
                duration: 30,
                pixelWidth: 100,
                pixelHeight: 100,
                posterJPEGData: nil
            )
        }
        let imported = try await library.importVideo(from: source)
        let first = try XCTUnwrap(local.insertLocalVideo(
            mediaID: imported.mediaID,
            filename: imported.filename,
            posterFilename: nil,
            title: imported.title,
            duration: 30,
            pixelWidth: 100,
            pixelHeight: 100,
            sortRank: 1
        ))
        let missing = try XCTUnwrap(local.insertLocalVideo(
            mediaID: UUID(),
            filename: "missing.mov",
            posterFilename: nil,
            title: "Missing",
            duration: 20,
            pixelWidth: 100,
            pixelHeight: 100,
            sortRank: 2
        ))
        let podcast = QueueItem(
            originalURL: URL(string: "https://example.com/episode")!,
            title: "Podcast",
            source: .podcast,
            status: .ready,
            sortRank: 3
        )
        podcast.playbackURLString = "https://cdn.example.com/episode.mp3"
        sharedContainer.mainContext.insert(podcast)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: library,
            engine: engine
        )
        await coordinator.select(first)
        await coordinator.play()
        engine.emit(.ended)

        for _ in 0..<20 where coordinator.currentItemID != podcast.id {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.currentItemID, podcast.id)
        XCTAssertEqual(missing.status, .ready)
        XCTAssertFalse(missing.isPlayed)
        XCTAssertNil(missing.unavailableReason)
    }

    func testCompletionAdvancesFromSelectedMiddleItemToFollowingItem() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let first = podcast(title: "First", rank: 1)
        let second = podcast(title: "Second", rank: 2)
        let third = podcast(title: "Third", rank: 3)
        sharedContainer.mainContext.insert(first)
        sharedContainer.mainContext.insert(second)
        sharedContainer.mainContext.insert(third)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: temporaryLibrary(),
            engine: engine
        )
        await coordinator.select(second)
        await coordinator.play()
        engine.emit(.ended)

        for _ in 0..<20 where coordinator.currentItemID != third.id {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.currentItemID, third.id)
        XCTAssertTrue(second.isPlayed)
        XCTAssertFalse(first.isPlayed)
    }

    func testPlayNextAtQueueEndStopsPlaybackAndSavesLatestProgress() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let item = podcast(title: "Only item", rank: 1)
        item.duration = 300
        sharedContainer.mainContext.insert(item)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: temporaryLibrary(),
            engine: engine
        )
        await coordinator.select(item)
        await coordinator.play()
        engine.emit(.timeChanged(position: 42, duration: 300))
        engine.emit(.timeChanged(position: 84, duration: 300))

        await coordinator.playNext()

        XCTAssertNil(coordinator.currentItemID)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(shared.item(id: item.id)?.playbackPosition, 84)
    }

    func testPausedPlaybackAdoptsProgressSavedByTheQueue() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let item = podcast(title: "Synced item", rank: 1)
        item.duration = 300
        item.playbackPosition = 15
        item.playbackRate = 1.25
        sharedContainer.mainContext.insert(item)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: temporaryLibrary(),
            engine: engine
        )
        await coordinator.select(item)
        shared.saveProgress(
            for: item,
            position: 120,
            duration: 360,
            rate: 1.75,
            force: true
        )

        coordinator.reconcileQueueState()

        XCTAssertEqual(coordinator.state, .paused)
        XCTAssertEqual(coordinator.position, 120)
        XCTAssertEqual(coordinator.duration, 360)
        XCTAssertEqual(coordinator.playbackRate, 1.75)
        XCTAssertEqual(engine.seekCalls.last, 120)
        XCTAssertEqual(engine.rateCalls.last, 1.75)
    }

    func testTransientExpiredSocialRefreshDoesNotLoadStaleURL() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [FailingSocialVideoProvider()])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let item = QueueItem(
            originalURL: URL(string: "https://x.com/example/status/123")!,
            title: "Expired video",
            source: .socialVideo,
            status: .ready,
            sortRank: 1
        )
        item.playbackURLString = "https://cdn.example.com/expired.mp4"
        item.playbackURLExpiresAt = .distantPast
        sharedContainer.mainContext.insert(item)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: temporaryLibrary(),
            engine: engine
        )
        await coordinator.select(item)

        XCTAssertEqual(coordinator.state, .needsUserAction)
        XCTAssertEqual(item.status, .ready)
        XCTAssertNil(item.unavailableReason)
        XCTAssertTrue(engine.loadedURLs.isEmpty)
    }

    func testCompletedRefreshCannotReplaceASelectionMadeWhileItWasPending() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let gate = ProviderGate()
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [GatedSocialVideoProvider(gate: gate)])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let expired = QueueItem(
            originalURL: URL(string: "https://x.com/example/status/456")!,
            title: "Expired video",
            source: .socialVideo,
            status: .ready,
            sortRank: 1
        )
        expired.playbackURLString = "https://cdn.example.com/expired.mp4"
        expired.playbackURLExpiresAt = .distantPast
        let selectedLater = podcast(title: "Selected later", rank: 2)
        sharedContainer.mainContext.insert(expired)
        sharedContainer.mainContext.insert(selectedLater)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: temporaryLibrary(),
            engine: engine
        )
        let pendingSelection = Task { await coordinator.select(expired) }
        await gate.waitUntilStarted()

        await coordinator.select(selectedLater)
        await gate.release()
        await pendingSelection.value

        XCTAssertEqual(coordinator.currentItemID, selectedLater.id)
        XCTAssertEqual(coordinator.state, .paused)
        XCTAssertEqual(engine.loadedURLs, [selectedLater.playbackURL])
    }

    func testQueueReconciliationStopsItemRemovedByStoreRefresh() async throws {
        let sharedContainer = try PersistenceController.makeContainer(inMemory: true).container
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let shared = QueueStore(
            context: sharedContainer.mainContext,
            providers: ProviderRegistry(providers: [])
        )
        let local = LocalQueueStore(context: localContainer.mainContext)
        let item = podcast(title: "Removed elsewhere", rank: 1)
        sharedContainer.mainContext.insert(item)
        try sharedContainer.mainContext.save()
        shared.refresh()

        let engine = MacTestPlaybackEngine()
        let coordinator = MacPlaybackCoordinator(
            sharedQueue: shared,
            localQueue: local,
            localMediaLibrary: temporaryLibrary(),
            engine: engine
        )
        await coordinator.select(item)
        await coordinator.play()
        XCTAssertTrue(engine.isPlaying)

        XCTAssertNotNil(shared.delete(item))
        coordinator.reconcileQueueState()

        XCTAssertNil(coordinator.currentItemID)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(engine.isPlaying)
    }

    private func podcast(title: String, rank: Double) -> QueueItem {
        let item = QueueItem(
            originalURL: URL(string: "https://example.com/\(title)")!,
            title: title,
            source: .podcast,
            status: .ready,
            sortRank: rank
        )
        item.playbackURLString = "https://cdn.example.com/\(title).mp3"
        return item
    }

    private func temporaryLibrary() -> LocalMediaLibrary {
        LocalMediaLibrary(
            root: FileManager.default.temporaryDirectory
                .appending(path: "PlaybackTests-\(UUID().uuidString)")
        )
    }
}

private struct FailingSocialVideoProvider: MediaProvider {
    let source = ProviderSource.socialVideo

    func canResolve(_ url: URL) -> Bool { true }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        throw ProviderResolutionError.network("Offline")
    }
}

private actor ProviderGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct GatedSocialVideoProvider: MediaProvider {
    let source = ProviderSource.socialVideo
    let gate: ProviderGate

    func canResolve(_ url: URL) -> Bool { true }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        await gate.waitUntilReleased()
        return ProviderResolvedItem(
            originalURL: url,
            canonicalURL: url,
            title: "Refreshed video",
            creatorName: nil,
            artworkURL: nil,
            duration: 30,
            publishedAt: nil,
            source: .socialVideo,
            playback: .remoteVideo(
                URL(string: "https://cdn.example.com/refreshed.mp4")!,
                expiresAt: Date().addingTimeInterval(3_600)
            ),
            isMadeForKids: false
        )
    }
}

@MainActor
private final class MacTestPlaybackEngine: PodcastPlaybackEngine {
    var eventHandler: ((UUID, PodcastPlaybackEvent) -> Void)?
    private(set) var isPlaying = false
    private(set) var loadedURLs: [URL] = []
    private(set) var seekCalls: [TimeInterval] = []
    private(set) var rateCalls: [Float] = []
    var renderingPlayer: AVPlayer? { nil }
    private var loadID: UUID?

    func load(url: URL, position: TimeInterval, rate: Float, loadID: UUID) {
        self.loadID = loadID
        loadedURLs.append(url)
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { seekCalls.append(time) }
    func setRate(_ rate: Float) { rateCalls.append(rate) }

    func emit(_ event: PodcastPlaybackEvent) {
        guard let loadID else { return }
        eventHandler?(loadID, event)
    }
}
