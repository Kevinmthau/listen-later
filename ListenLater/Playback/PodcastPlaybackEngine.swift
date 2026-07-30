import AVFoundation
import Foundation

enum PodcastPlaybackEvent: Equatable {
    case timeChanged(position: TimeInterval, duration: TimeInterval)
    case ended
    case failed(String)
}

@MainActor
protocol PodcastPlaybackEngine: AnyObject {
    var eventHandler: ((UUID, PodcastPlaybackEvent) -> Void)? { get set }
    var isPlaying: Bool { get }

    func load(
        url: URL,
        position: TimeInterval,
        rate: Float,
        loadID: UUID
    )
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func setRate(_ rate: Float)
}

@MainActor
final class AVPlayerPodcastEngine: PodcastPlaybackEngine {
    var eventHandler: ((UUID, PodcastPlaybackEvent) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var playbackWatchdogTask: Task<Void, Never>?
    private var preferredRate: Float = 1
    private var activeLoadID: UUID?
    private var wantsPlayback = false
    private let loadIdentity = PodcastLoadIdentity()
    private let playbackWatchdogDelay: @Sendable () async throws -> Void

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    init(
        playbackWatchdogDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(30))
        }
    ) {
        self.playbackWatchdogDelay = playbackWatchdogDelay
        let loadIdentity = loadIdentity
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // Snapshot the load generation before hopping to MainActor. If a
            // new item loads while this callback is queued, the coordinator
            // will reject this old generation.
            guard let loadID = loadIdentity.current else { return }
            Task { @MainActor in
                guard let self,
                      let item = self.player.currentItem,
                      self.activeLoadID == loadID
                else {
                    return
                }
                let duration = item.duration.seconds
                self.eventHandler?(
                    loadID,
                    .timeChanged(
                        position: time.seconds.isFinite ? time.seconds : 0,
                        duration: duration.isFinite ? duration : 0
                    )
                )
            }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] player, _ in
            guard let loadID = loadIdentity.current else { return }
            let status = player.timeControlStatus
            Task { @MainActor in
                self?.timeControlStatusDidChange(status, loadID: loadID)
            }
        }
    }

    func tearDown() {
        wantsPlayback = false
        cancelPlaybackWatchdog()
        activeLoadID = nil
        loadIdentity.current = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        statusObservation = nil
        timeControlObservation = nil
    }

    func load(
        url: URL,
        position: TimeInterval,
        rate: Float,
        loadID: UUID
    ) {
        clearItemObservers()
        wantsPlayback = false
        preferredRate = rate
        activeLoadID = loadID

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        installObservers(for: item, loadID: loadID)
        loadIdentity.current = loadID

        if position > 0 {
            let target = CMTime(seconds: position, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func play() {
        guard let activeLoadID else { return }
        wantsPlayback = true
        player.playImmediately(atRate: preferredRate)
        armPlaybackWatchdog(for: activeLoadID)
    }

    func pause() {
        wantsPlayback = false
        cancelPlaybackWatchdog()
        player.pause()
    }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Float) {
        preferredRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    private func installObservers(for item: AVPlayerItem, loadID: UUID) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finishActiveLoad(loadID)
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Playback failed."
            Task { @MainActor in
                self?.failActiveLoad(loadID, message: message)
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.wantsPlayback,
                      self.activeLoadID == loadID
                else {
                    return
                }
                self.armPlaybackWatchdog(for: loadID)
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                self?.failActiveLoad(
                    loadID,
                    message: item.error?.localizedDescription ?? "Playback failed."
                )
            }
        }
    }

    private func clearItemObservers() {
        wantsPlayback = false
        cancelPlaybackWatchdog()
        activeLoadID = nil
        loadIdentity.current = nil
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
    }

    private func timeControlStatusDidChange(
        _ status: AVPlayer.TimeControlStatus,
        loadID: UUID
    ) {
        guard wantsPlayback, activeLoadID == loadID else {
            return
        }
        switch status {
        case .playing:
            cancelPlaybackWatchdog()
        case .paused, .waitingToPlayAtSpecifiedRate:
            armPlaybackWatchdog(for: loadID)
        @unknown default:
            armPlaybackWatchdog(for: loadID)
        }
    }

    private func armPlaybackWatchdog(for loadID: UUID) {
        guard wantsPlayback,
              activeLoadID == loadID,
              playbackWatchdogTask == nil
        else {
            return
        }

        let delay = playbackWatchdogDelay
        playbackWatchdogTask = Task { [weak self] in
            do {
                try await delay()
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.playbackWatchdogTask = nil
            self.failActiveLoad(
                loadID,
                message: "Podcast playback did not start or recover within 30 seconds."
            )
        }
    }

    private func cancelPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
    }

    private func finishActiveLoad(_ loadID: UUID) {
        guard activeLoadID == loadID else { return }
        wantsPlayback = false
        cancelPlaybackWatchdog()
        activeLoadID = nil
        loadIdentity.current = nil
        eventHandler?(loadID, .ended)
    }

    private func failActiveLoad(_ loadID: UUID, message: String) {
        guard activeLoadID == loadID else { return }
        wantsPlayback = false
        cancelPlaybackWatchdog()
        activeLoadID = nil
        loadIdentity.current = nil
        player.pause()
        eventHandler?(loadID, .failed(message))
    }
}

private final class PodcastLoadIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UUID?

    var current: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
