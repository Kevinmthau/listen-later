import AVFoundation
import Foundation
import MediaPlayer
import Observation

enum PlaybackTransportState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case waitingForForeground
    case needsUserAction
    case requiresYouTubeApp

    var isPlaying: Bool {
        self == .playing
    }
}

@MainActor
@Observable
final class PlaybackCoordinator {
    private(set) var currentItemID: UUID?
    private(set) var transportState: PlaybackTransportState = .idle
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var playbackRate: Double = 1
    private(set) var isForeground = true
    var notice: String?

    let youtubePlayer: YouTubePlayerModel

    @ObservationIgnored private let queue: QueueStore
    @ObservationIgnored private let podcastEngine: PodcastPlaybackEngine
    @ObservationIgnored private let audioSession: AVAudioSession
    @ObservationIgnored private var preparedItemID: UUID?
    @ObservationIgnored private var pendingResolutionAutoplayItemID: UUID?
    @ObservationIgnored private var activePodcastLoadID: UUID?
    @ObservationIgnored private var activeYouTubeLoadID: UUID?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []

    var currentItem: QueueItem? {
        queue.item(id: currentItemID)
    }

    init(
        queue: QueueStore,
        podcastEngine: PodcastPlaybackEngine? = nil,
        youtubePlayer: YouTubePlayerModel? = nil,
        audioSession: AVAudioSession? = nil
    ) {
        let podcastEngine = podcastEngine ?? AVPlayerPodcastEngine()
        let youtubePlayer = youtubePlayer ?? YouTubePlayerModel()
        self.queue = queue
        self.podcastEngine = podcastEngine
        self.youtubePlayer = youtubePlayer
        self.audioSession = audioSession ?? .sharedInstance()

        podcastEngine.eventHandler = { [weak self] loadID, event in
            self?.handlePodcastEvent(loadID: loadID, event: event)
        }
        youtubePlayer.eventHandler = { [weak self] loadID, event in
            self?.handleYouTubeEvent(loadID: loadID, event: event)
        }
        queue.resolutionHandler = { [weak self] item in
            self?.resolutionDidFinish(item)
        }

        if let resumeItem = queue.resumeCandidate() {
            currentItemID = resumeItem.id
            position = resumeItem.playbackPosition
            duration = resumeItem.duration
            playbackRate = resumeItem.playbackRate > 0 ? resumeItem.playbackRate : 1
            transportState = .paused
        }

        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
    }

    func tearDown() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    func playOrPause() {
        if transportState.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let item = currentItem else {
            guard let first = queue.firstUnplayed() else {
                notice = "Your queue is caught up."
                return
            }
            start(first)
            return
        }

        guard item.status == .ready else {
            if item.status == .unavailable {
                advanceAfterFailure()
            } else {
                pendingResolutionAutoplayItemID = item.id
                transportState = .loading
                notice = "This item is still resolving."
            }
            return
        }

        guard preparedItemID == item.id else {
            start(item)
            return
        }

        switch item.source {
        case .podcast:
            activateAudioSession()
            podcastEngine.play()
            transportState = .playing
            updateNowPlaying()
        case .youtube:
            guard isForeground else {
                transportState = .waitingForForeground
                notice = "Open MushRadio to play this YouTube video."
                return
            }
            if item.youtubeMadeForKids {
                transportState = .requiresYouTubeApp
                return
            }
            youtubePlayer.play()
            transportState = youtubePlayer.isReady ? .loading : .needsUserAction
        }
    }

    func start(_ item: QueueItem, autoplay: Bool = true) {
        saveCurrentProgress(force: true)
        let canKeepPodcastSession =
            currentItem?.source == .podcast
            && item.source == .podcast
            && item.status == .ready
        let shouldDeactivatePodcastSession =
            currentItem?.source == .podcast
            && !canKeepPodcastSession
        parkCurrentTransport(
            deactivateAudioSession: shouldDeactivatePodcastSession
        )
        notice = nil
        currentItemID = item.id
        preparedItemID = nil
        pendingResolutionAutoplayItemID = nil
        if item.isPlayed {
            queue.markUnplayed(item)
        }
        position = item.playbackPosition
        duration = item.duration
        playbackRate = item.playbackRate > 0 ? item.playbackRate : 1
        item.lastPlayedAt = Date()
        queue.saveProgress(
            for: item,
            position: position,
            duration: duration,
            rate: playbackRate,
            force: true
        )

        guard item.status == .ready else {
            if item.status == .unavailable {
                advanceAfterFailure()
            } else {
                if autoplay {
                    pendingResolutionAutoplayItemID = item.id
                }
                transportState = .loading
                notice = "This item is still resolving."
            }
            return
        }

        switch item.source {
        case .podcast:
            startPodcast(item, autoplay: autoplay)
        case .youtube:
            startYouTube(item, autoplay: autoplay)
        }
    }

    func pause() {
        pendingResolutionAutoplayItemID = nil
        guard let item = currentItem else {
            podcastEngine.pause()
            youtubePlayer.pause()
            activePodcastLoadID = nil
            preparedItemID = nil
            transportState = .idle
            clearNowPlaying()
            return
        }
        switch item.source {
        case .podcast:
            podcastEngine.pause()
        case .youtube:
            youtubePlayer.pause()
        }
        transportState = .paused
        saveCurrentProgress(force: true)
        updateNowPlaying()
    }

    func skipForward(seconds: TimeInterval = 30) {
        seek(to: position + seconds)
    }

    func skipBack(seconds: TimeInterval = 15) {
        seek(to: position - seconds)
    }

    func seek(to target: TimeInterval) {
        guard let item = currentItem else { return }
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = min(max(0, target), upperBound)
        position = clamped
        switch item.source {
        case .podcast:
            podcastEngine.seek(to: clamped)
        case .youtube:
            youtubePlayer.seek(to: clamped)
        }
        queue.saveProgress(
            for: item,
            position: clamped,
            duration: duration,
            rate: playbackRate,
            force: true
        )
        updateNowPlaying()
    }

    func setPlaybackRate(_ rate: Double) {
        let supported = [0.75, 1, 1.25, 1.5, 1.75, 2]
        playbackRate = supported.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1
        guard let item = currentItem else { return }
        item.playbackRate = playbackRate
        switch item.source {
        case .podcast:
            podcastEngine.setRate(Float(playbackRate))
        case .youtube:
            youtubePlayer.setPlaybackRate(playbackRate)
        }
        queue.saveProgress(
            for: item,
            position: position,
            duration: duration,
            rate: playbackRate,
            force: true
        )
        updateNowPlaying()
    }

    func playNext() {
        guard let item = currentItem else {
            if let first = queue.firstUnplayed() {
                start(first)
            }
            return
        }
        queue.markPlayed(item)
        guard let next = queue.nextUnplayed(after: item) else {
            finishQueue()
            return
        }
        start(next)
    }

    func sceneDidBecomeActive() {
        isForeground = true
        if transportState == .waitingForForeground, let item = currentItem {
            startYouTube(item, autoplay: false)
            if transportState == .loading {
                transportState = .paused
                notice = "Tap Play to continue this YouTube video."
            }
        }
    }

    func sceneWillResignActive() {
        isForeground = false
        saveCurrentProgress(force: true)
        guard currentItem?.source == .youtube else { return }
        activeYouTubeLoadID = nil
        preparedItemID = nil
        youtubePlayer.pause()
        transportState = .waitingForForeground
        notice = "YouTube playback requires the app to remain open."
        clearNowPlaying()
    }

    func youtubePlayerWillBeCovered() {
        guard currentItem?.source == .youtube else { return }
        pendingResolutionAutoplayItemID = nil
        activeYouTubeLoadID = nil
        preparedItemID = nil
        youtubePlayer.pause()
        transportState = .needsUserAction
        notice = "Tap Play to continue this YouTube video."
        saveCurrentProgress(force: true)
        clearNowPlaying()
    }

    func currentItemWasDeleted() {
        if queue.item(id: currentItemID) == nil {
            podcastEngine.pause()
            youtubePlayer.pause()
            setRemoteCommandsEnabled(false)
            try? audioSession.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            currentItemID = nil
            preparedItemID = nil
            pendingResolutionAutoplayItemID = nil
            activePodcastLoadID = nil
            activeYouTubeLoadID = nil
            transportState = .idle
            position = 0
            duration = 0
            clearNowPlaying()
        }
    }

    func reconcileQueueState() {
        guard currentItemID != nil else { return }
        guard let item = currentItem else {
            currentItemWasDeleted()
            return
        }

        if item.status == .unavailable {
            notice = "This item became unavailable. Skipping it."
            advanceAfterFailure()
            return
        }

        // The device actively producing progress remains authoritative for
        // that playback session. This prevents a delayed CloudKit merge from
        // seeking playback backward, and prevents near-end progress from
        // stopping the player before its terminal event advances the queue.
        if transportState == .playing {
            queue.saveProgress(
                for: item,
                position: position,
                duration: duration,
                rate: playbackRate,
                force: true
            )
            return
        }

        if item.isPlayed {
            notice = "Playback progress was updated on another device."
            advance(from: item)
            return
        }

        position = max(0, item.playbackPosition)
        duration = max(0, item.duration)
        playbackRate = item.playbackRate > 0 ? item.playbackRate : 1

        if preparedItemID == item.id {
            switch item.source {
            case .podcast:
                podcastEngine.seek(to: position)
                podcastEngine.setRate(Float(playbackRate))
                updateNowPlaying()
            case .youtube:
                youtubePlayer.seek(to: position)
                youtubePlayer.setPlaybackRate(playbackRate)
            }
        } else if transportState == .loading, item.status == .ready {
            transportState = .paused
            notice = "Tap Play to continue from your synced position."
        }
    }

    private func startPodcast(_ item: QueueItem, autoplay: Bool) {
        guard let url = item.playbackURL else {
            queue.markUnavailable(item, reason: "The podcast audio URL is missing.")
            advanceAfterFailure()
            return
        }
        youtubePlayer.pause()
        activateAudioSession()
        let loadID = UUID()
        activePodcastLoadID = loadID
        podcastEngine.load(
            url: url,
            position: position,
            rate: Float(playbackRate),
            loadID: loadID
        )
        preparedItemID = item.id
        setRemoteCommandsEnabled(true)
        if autoplay {
            podcastEngine.play()
            transportState = .playing
        } else {
            transportState = .paused
        }
        updateNowPlaying()
    }

    private func startYouTube(_ item: QueueItem, autoplay: Bool) {
        podcastEngine.pause()
        activePodcastLoadID = nil
        activeYouTubeLoadID = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        setRemoteCommandsEnabled(false)
        clearNowPlaying()

        guard isForeground else {
            transportState = .waitingForForeground
            notice = "Open MushRadio to play this YouTube video."
            return
        }
        guard !item.youtubeMadeForKids else {
            transportState = .requiresYouTubeApp
            notice = "For children’s content, use the official YouTube app."
            return
        }
        guard let videoID = item.youtubeVideoID else {
            queue.markUnavailable(item, reason: "The YouTube video ID is missing.")
            advanceAfterFailure()
            return
        }

        preparedItemID = item.id
        transportState = .loading
        let loadID = UUID()
        activeYouTubeLoadID = loadID
        youtubePlayer.load(
            videoID: videoID,
            position: position,
            autoplay: autoplay,
            playbackRate: playbackRate,
            loadID: loadID
        )
    }

    private func handlePodcastEvent(
        loadID: UUID,
        event: PodcastPlaybackEvent
    ) {
        guard activePodcastLoadID == loadID,
              let item = currentItem,
              item.source == .podcast
        else {
            return
        }
        switch event {
        case let .timeChanged(newPosition, newDuration):
            let durationChanged = newDuration > 0 && newDuration != duration
            position = newPosition
            if newDuration > 0 {
                duration = newDuration
            }
            queue.saveProgress(
                for: item,
                position: newPosition,
                duration: newDuration,
                rate: playbackRate
            )
            if durationChanged {
                updateNowPlaying()
            }
        case .ended:
            activePodcastLoadID = nil
            queue.markPlayed(item)
            advance(from: item)
        case let .stalled(message):
            activePodcastLoadID = nil
            preparedItemID = nil
            transportState = .needsUserAction
            notice = "\(message) Tap Play to retry."
            saveCurrentProgress(force: true)
            updateNowPlaying()
        case let .failed(message):
            activePodcastLoadID = nil
            queue.markUnavailable(item, reason: message)
            notice = "Skipped an unavailable podcast episode."
            advanceAfterFailure()
        }
    }

    private func handleYouTubeEvent(
        loadID: UUID,
        event: YouTubePlayerEvent
    ) {
        guard activeYouTubeLoadID == loadID,
              let item = currentItem,
              item.source == .youtube
        else {
            return
        }
        switch event {
        case .ready:
            break
        case .playing:
            transportState = .playing
        case .paused:
            if transportState == .playing || transportState == .loading {
                transportState = .paused
            }
            saveCurrentProgress(force: true)
        case .ended:
            activeYouTubeLoadID = nil
            queue.markPlayed(item)
            advance(from: item)
        case let .progress(newPosition, newDuration):
            position = newPosition
            if newDuration > 0 {
                duration = newDuration
            }
            queue.saveProgress(
                for: item,
                position: newPosition,
                duration: newDuration,
                rate: playbackRate
            )
        case let .playbackRateChanged(actualRate):
            guard actualRate.isFinite, actualRate > 0 else { return }
            playbackRate = actualRate
            queue.saveProgress(
                for: item,
                position: position,
                duration: duration,
                rate: actualRate,
                force: true
            )
        case .autoplayBlocked:
            transportState = .needsUserAction
            notice = "Tap Play to start this YouTube video."
        case let .failed(code):
            if code == 153 {
                transportState = .needsUserAction
                notice = "The YouTube player is missing its client identity. Check setup."
            } else if [2, 5, 100, 101, 150].contains(code) {
                activeYouTubeLoadID = nil
                queue.markUnavailable(item, reason: "YouTube player error \(code).")
                notice = "Skipped an unavailable YouTube video."
                advanceAfterFailure()
            } else {
                transportState = .needsUserAction
                notice = "YouTube playback stopped with error \(code)."
            }
        }
    }

    private func resolutionDidFinish(_ item: QueueItem) {
        guard currentItemID == item.id,
              preparedItemID == nil,
              transportState == .loading
        else {
            return
        }

        let shouldAutoplay = pendingResolutionAutoplayItemID == item.id
        pendingResolutionAutoplayItemID = nil

        if item.status == .ready {
            start(item, autoplay: shouldAutoplay)
        } else if item.status == .unavailable {
            advanceAfterFailure()
        }
    }

    private func advance(from item: QueueItem) {
        guard let next = queue.nextUnplayed(after: item) else {
            finishQueue()
            return
        }
        start(next)
    }

    private func advanceAfterFailure() {
        guard let item = currentItem else {
            finishQueue()
            return
        }
        guard let next = queue.nextUnplayed(after: item) else {
            finishQueue()
            return
        }
        start(next)
    }

    private func finishQueue() {
        podcastEngine.pause()
        youtubePlayer.pause()
        setRemoteCommandsEnabled(false)
        try? audioSession.setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        currentItemID = nil
        preparedItemID = nil
        pendingResolutionAutoplayItemID = nil
        activePodcastLoadID = nil
        activeYouTubeLoadID = nil
        transportState = .idle
        position = 0
        duration = 0
        clearNowPlaying()
        notice = "Queue finished."
    }

    private func parkCurrentTransport(
        deactivateAudioSession: Bool = false
    ) {
        podcastEngine.pause()
        youtubePlayer.pause()
        activePodcastLoadID = nil
        activeYouTubeLoadID = nil
        setRemoteCommandsEnabled(false)
        if deactivateAudioSession {
            try? audioSession.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        clearNowPlaying()
    }

    private func saveCurrentProgress(force: Bool) {
        guard let item = currentItem, !item.isPlayed else { return }
        queue.saveProgress(
            for: item,
            position: position,
            duration: duration,
            rate: playbackRate,
            force: force
        )
    }

    private func configureAudioSession() {
        do {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
        } catch {
            notice = "Background audio setup failed: \(error.localizedDescription)"
        }
    }

    private func activateAudioSession() {
        do {
            try audioSession.setActive(true)
        } catch {
            notice = "Audio output is unavailable: \(error.localizedDescription)"
        }
    }

    private func observeAudioSession() {
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions =
                notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                ?? 0
            Task { @MainActor in
                guard
                    let rawValue,
                    let type = AVAudioSession.InterruptionType(rawValue: rawValue)
                else { return }
                switch type {
                case .began:
                    guard let self, self.currentItem?.source == .podcast else {
                        return
                    }
                    self.wasPlayingBeforeInterruption = self.transportState.isPlaying
                    self.pause()
                case .ended:
                    guard let self else { return }
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    let shouldResume = options.contains(.shouldResume)
                    let resume = self.wasPlayingBeforeInterruption && shouldResume
                    self.wasPlayingBeforeInterruption = false
                    if resume {
                        self.play()
                    }
                @unknown default:
                    break
                }
            }
        }
        notificationObservers.append(interruption)

        let routeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard
                    let rawValue,
                    AVAudioSession.RouteChangeReason(rawValue: rawValue) == .oldDeviceUnavailable
                else { return }
                self?.pause()
            }
        }
        notificationObservers.append(routeChange)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.changePlaybackRateCommand.supportedPlaybackRates = [
            0.75, 1, 1.25, 1.5, 1.75, 2
        ]

        addTarget(to: center.playCommand) { $0.play() }
        addTarget(to: center.pauseCommand) { $0.pause() }
        addTarget(to: center.togglePlayPauseCommand) { $0.playOrPause() }
        addTarget(to: center.nextTrackCommand) { $0.playNext() }
        addTarget(to: center.skipForwardCommand) { $0.skipForward() }
        addTarget(to: center.skipBackwardCommand) { $0.skipBack() }

        let positionTarget = center.changePlaybackPositionCommand.addTarget {
            [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = event.positionTime
            Task { @MainActor in self?.seek(to: positionTime) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, positionTarget))

        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let playbackRate = Double(event.playbackRate)
            Task { @MainActor in self?.setPlaybackRate(playbackRate) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackRateCommand, rateTarget))
        setRemoteCommandsEnabled(false)
    }

    private func addTarget(
        to command: MPRemoteCommand,
        action: @escaping @Sendable @MainActor (PlaybackCoordinator) -> Void
    ) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
        center.changePlaybackRateCommand.isEnabled = enabled
    }

    private func updateNowPlaying() {
        guard let item = currentItem, item.source == .podcast else {
            clearNowPlaying()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: transportState.isPlaying ? playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let index = queue.items.firstIndex(where: { $0.id == item.id }) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.items.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
