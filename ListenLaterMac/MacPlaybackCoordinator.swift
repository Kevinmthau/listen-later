import AppKit
import AVFoundation
import Foundation
import Observation

enum MacPlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case missingLocalMedia
    case externalPlayback
    case needsUserAction
}

@MainActor
@Observable
final class MacPlaybackCoordinator {
    private(set) var currentItemID: UUID?
    private(set) var state: MacPlaybackState = .idle
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var playbackRate: Double = 1
    var notice: String?

    @ObservationIgnored private let sharedQueue: QueueStore
    @ObservationIgnored private let localQueue: LocalQueueStore
    @ObservationIgnored private let localMediaLibrary: LocalMediaLibrary
    @ObservationIgnored private let engine: PodcastPlaybackEngine
    @ObservationIgnored private var activeLoadID: UUID?
    @ObservationIgnored private var pendingStartID = UUID()
    @ObservationIgnored private var pendingAutoplayItemID: UUID?

    var currentItem: QueueItem? {
        item(id: currentItemID)
    }

    var nativePlayer: AVPlayer? {
        activeLoadID == nil ? nil : engine.renderingPlayer
    }

    init(
        sharedQueue: QueueStore,
        localQueue: LocalQueueStore,
        localMediaLibrary: LocalMediaLibrary,
        engine: PodcastPlaybackEngine? = nil
    ) {
        self.sharedQueue = sharedQueue
        self.localQueue = localQueue
        self.localMediaLibrary = localMediaLibrary
        let engine = engine ?? AVPlayerPodcastEngine()
        self.engine = engine
        engine.eventHandler = { [weak self] loadID, event in
            self?.handle(loadID: loadID, event: event)
        }
    }

    func select(_ item: QueueItem) async {
        guard item.id != currentItemID else { return }
        await start(item, autoplay: false, automatic: false)
    }

    func playOrPause() async {
        if state == .playing {
            pause()
        } else {
            await play()
        }
    }

    func play() async {
        guard let item = currentItem else {
            if let first = playableItems.first {
                await start(first, autoplay: true, automatic: true)
            }
            return
        }
        if item.source == .youtube {
            openYouTube(item)
            return
        }
        if state == .paused, activeLoadID != nil {
            if item.isPlayed {
                markUnplayed(item)
                position = 0
                engine.seek(to: 0)
            }
            engine.play()
            state = .playing
            notice = nil
            recordPlaybackStarted(for: item)
            return
        }
        await start(item, autoplay: true, automatic: false)
    }

    func pause() {
        invalidatePendingStart()
        engine.pause()
        guard currentItem != nil else { return }
        state = .paused
        saveProgress(force: true)
    }

    func playNext() async {
        await startNext(after: currentItemID, automatic: false)
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), duration > 0 ? duration : time)
        position = clamped
        engine.seek(to: clamped)
        saveProgress(force: true)
    }

    func setPlaybackRate(_ rate: Double) {
        let supported = [0.75, 1, 1.25, 1.5, 1.75, 2]
        playbackRate = supported.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1
        engine.setRate(Float(playbackRate))
        saveProgress(force: true)
    }

    func itemWasDeleted(_ id: UUID) {
        guard currentItemID == id else { return }
        invalidatePendingStart()
        engine.pause()
        activeLoadID = nil
        pendingAutoplayItemID = nil
        currentItemID = nil
        state = .idle
        position = 0
        duration = 0
    }

    /// Reconciles the current item after a local or CloudKit-backed store
    /// refresh. Active playback remains authoritative; a paused player adopts
    /// progress saved elsewhere.
    func reconcileQueueState() {
        guard let currentItemID else { return }
        guard let item = item(id: currentItemID) else {
            itemWasDeleted(currentItemID)
            notice = "This item was removed from the queue."
            return
        }

        if item.status == .unavailable {
            saveProgress(force: true)
            engine.pause()
            activeLoadID = nil
            state = .loading
            notice = "This item became unavailable. Skipping it."
            scheduleAutomaticAdvance(after: item.id)
            return
        }

        if state == .playing {
            let storedProgressDisagrees =
                abs(item.playbackPosition - position) >= 0.5
                || abs(item.playbackRate - playbackRate) >= 0.001
            guard item.isPlayed || storedProgressDisagrees else { return }
            if item.source == .localVideo {
                if item.isPlayed {
                    localQueue.markUnplayed(item)
                }
            } else {
                item.isPlayed = false
            }
            saveProgress(force: true)
            return
        }

        if item.isPlayed {
            notice = "Playback progress was updated on another device."
            scheduleAutomaticAdvance(after: item.id)
            return
        }

        let syncedPosition = max(0, item.playbackPosition)
        let syncedRate = item.playbackRate > 0 && item.playbackRate.isFinite
            ? item.playbackRate
            : 1
        let syncedProgressChanged =
            abs(syncedPosition - position) >= 0.5
            || abs(syncedRate - playbackRate) >= 0.001
        position = syncedPosition
        duration = max(0, item.duration)
        playbackRate = syncedRate

        if syncedProgressChanged, activeLoadID != nil {
            engine.seek(to: position)
            engine.setRate(Float(playbackRate))
        }
        if state == .loading, item.status == .ready {
            if pendingAutoplayItemID == item.id {
                pendingAutoplayItemID = nil
                let itemID = item.id
                let resumeID = UUID()
                pendingStartID = resumeID
                Task { [weak self] in
                    guard let self,
                          self.isCurrentStart(resumeID, itemID: itemID)
                    else { return }
                    await self.start(item, autoplay: true, automatic: true)
                }
            } else {
                state = .paused
                notice = "Continue from your synced position."
            }
        }
    }

    func openYouTube(_ item: QueueItem) {
        guard item.source == .youtube,
              let url = item.canonicalURL ?? item.originalURL
        else { return }
        invalidatePendingStart()
        engine.pause()
        activeLoadID = nil
        currentItemID = item.id
        state = .externalPlayback
        notice = "YouTube plays in the official app or website on Mac."
        NSWorkspace.shared.open(url)
    }

    private func start(
        _ item: QueueItem,
        autoplay: Bool,
        automatic: Bool
    ) async {
        let startID = UUID()
        pendingStartID = startID
        pendingAutoplayItemID = nil
        saveProgress(force: true)
        engine.pause()
        activeLoadID = nil
        currentItemID = item.id
        position = max(0, item.playbackPosition)
        duration = max(0, item.duration)
        playbackRate = item.playbackRate > 0 ? item.playbackRate : 1
        notice = nil

        guard item.status == .ready else {
            state = .loading
            notice = item.status == .unavailable
                ? (item.unavailableReason ?? "This item is unavailable.")
                : "This item is still resolving."
            if item.status == .resolving, autoplay {
                pendingAutoplayItemID = item.id
            }
            if automatic, item.status == .unavailable {
                await startNext(after: item.id, automatic: true)
            }
            return
        }

        switch item.source {
        case .localVideo:
            guard let mediaID = item.localMediaID else {
                state = .missingLocalMedia
                notice = "This video is not available on this Mac. It remains in the queue and is not marked unavailable or played."
                if automatic {
                    await startNext(after: item.id, automatic: true)
                }
                return
            }
            let url = await localMediaLibrary.playbackURL(
                mediaID: mediaID,
                filename: item.localFilename
            )
            guard isCurrentStart(startID, itemID: item.id) else { return }
            guard let url else {
                state = .missingLocalMedia
                notice = "This video is not available on this Mac. It remains in the queue and is not marked unavailable or played."
                if automatic {
                    await startNext(after: item.id, automatic: true)
                }
                return
            }
            load(url: url, item: item, autoplay: autoplay)
        case .podcast, .socialVideo:
            if item.playbackURLNeedsRefresh() {
                await sharedQueue.refreshPlaybackURL(for: item)
                guard isCurrentStart(startID, itemID: item.id) else { return }
                guard item.status == .ready else {
                    state = .needsUserAction
                    notice = item.unavailableReason ?? "This item is unavailable."
                    if automatic {
                        await startNext(after: item.id, automatic: true)
                    }
                    return
                }
                guard !item.playbackURLNeedsRefresh() else {
                    state = .needsUserAction
                    notice = "The media link could not be refreshed. Press Play to try again."
                    return
                }
            }
            guard let url = item.playbackURL else {
                sharedQueue.markUnavailable(item, reason: "The media URL is missing.")
                if automatic {
                    await startNext(after: item.id, automatic: true)
                } else {
                    state = .needsUserAction
                    notice = "The media URL is missing."
                }
                return
            }
            load(url: url, item: item, autoplay: autoplay)
        case .youtube:
            state = .externalPlayback
            notice = "YouTube plays in the official app or website on Mac."
            if automatic {
                await startNext(after: item.id, automatic: true)
            }
        case .unknown:
            state = .needsUserAction
            notice = "This item was created by a newer version of MushRadio."
            if automatic {
                await startNext(after: item.id, automatic: true)
            }
        }
    }

    private func load(url: URL, item: QueueItem, autoplay: Bool) {
        if autoplay, item.isPlayed {
            markUnplayed(item)
            position = 0
        }
        let loadID = UUID()
        activeLoadID = loadID
        engine.load(
            url: url,
            position: position,
            rate: Float(playbackRate),
            loadID: loadID
        )
        if autoplay {
            engine.play()
            state = .playing
            recordPlaybackStarted(for: item)
        } else {
            state = .paused
        }
    }

    private func startNext(after itemID: UUID?, automatic: Bool) async {
        invalidatePendingStart()
        let items = orderedItems
        let next: QueueItem?
        if let itemID, let index = items.firstIndex(where: { $0.id == itemID }) {
            next = items.dropFirst(index + 1).first { !$0.isInPlayedSection }
        } else {
            next = items.first { !$0.isInPlayedSection }
        }
        guard let next else {
            finishQueue()
            return
        }
        await start(next, autoplay: true, automatic: automatic)
    }

    private func scheduleAutomaticAdvance(after itemID: UUID) {
        Task { [weak self] in
            guard let self, self.currentItemID == itemID else { return }
            await self.startNext(after: itemID, automatic: true)
        }
    }

    private func finishQueue() {
        saveProgress(force: true)
        invalidatePendingStart()
        engine.pause()
        activeLoadID = nil
        pendingAutoplayItemID = nil
        currentItemID = nil
        state = .idle
        position = 0
        duration = 0
        notice = "Queue finished."
    }

    private func invalidatePendingStart() {
        pendingStartID = UUID()
        pendingAutoplayItemID = nil
    }

    private func isCurrentStart(_ startID: UUID, itemID: UUID) -> Bool {
        pendingStartID == startID && currentItemID == itemID
    }

    private func handle(loadID: UUID, event: PodcastPlaybackEvent) {
        guard activeLoadID == loadID, let item = currentItem else { return }
        switch event {
        case let .timeChanged(newPosition, newDuration):
            position = max(0, newPosition)
            if newDuration.isFinite, newDuration > 0 {
                duration = newDuration
            }
            saveProgress(force: false)
        case let .bufferingChanged(isBuffering):
            if isBuffering, state == .playing {
                notice = "Buffering…"
            } else if notice == "Buffering…" {
                notice = nil
            }
        case .pausedExternally:
            state = .paused
            saveProgress(force: true)
        case .resumedExternally:
            state = .playing
        case .ended:
            activeLoadID = nil
            markPlayed(item)
            Task { [weak self] in
                await self?.startNext(after: item.id, automatic: true)
            }
        case let .stalled(message):
            activeLoadID = nil
            state = .needsUserAction
            notice = "\(message) Press Play to retry."
            saveProgress(force: true)
        case let .failed(message):
            activeLoadID = nil
            if item.source == .localVideo {
                state = .needsUserAction
                notice = "Local playback failed: \(message)"
            } else {
                sharedQueue.markUnavailable(item, reason: message)
                Task { [weak self] in
                    await self?.startNext(after: item.id, automatic: true)
                }
            }
        }
    }

    private func saveProgress(force: Bool) {
        guard let item = currentItem, !item.isPlayed else { return }
        if item.source == .localVideo {
            localQueue.saveProgress(
                for: item,
                position: position,
                duration: duration,
                rate: playbackRate,
                force: force
            )
        } else {
            sharedQueue.saveProgress(
                for: item,
                position: position,
                duration: duration,
                rate: playbackRate,
                force: force
            )
        }
    }

    private func markPlayed(_ item: QueueItem) {
        if item.source == .localVideo {
            localQueue.markPlayed(item)
        } else {
            sharedQueue.markPlayed(item)
        }
    }

    private func markUnplayed(_ item: QueueItem) {
        if item.source == .localVideo {
            localQueue.markUnplayed(item)
        } else {
            sharedQueue.markUnplayed(item)
        }
    }

    private func recordPlaybackStarted(for item: QueueItem) {
        if item.source == .localVideo {
            localQueue.recordPlaybackStarted(for: item)
        } else {
            sharedQueue.recordPlaybackStarted(for: item)
        }
    }

    private var playableItems: [QueueItem] {
        orderedItems.filter { !$0.isInPlayedSection }
    }

    private var orderedItems: [QueueItem] {
        (sharedQueue.items + localQueue.items)
            .sorted {
                if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private func item(id: UUID?) -> QueueItem? {
        guard let id else { return nil }
        return sharedQueue.item(id: id) ?? localQueue.item(id: id)
    }
}
