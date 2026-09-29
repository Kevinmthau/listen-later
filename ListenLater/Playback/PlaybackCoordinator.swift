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

enum SleepTimer: Equatable {
    case off
    /// Pause playback at this time.
    case until(Date)
    /// Pause when the current item finishes instead of advancing.
    case endOfItem
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
    /// Playback is wanted but the player is still waiting for media.
    private(set) var isBuffering = false
    private(set) var sleepTimer: SleepTimer = .off
    var notice: String?

    let youtubePlayer: YouTubePlayerModel

    @ObservationIgnored private let queue: QueueStore
    @ObservationIgnored private let podcastEngine: PodcastPlaybackEngine
    @ObservationIgnored private let audioSession: AVAudioSession
    @ObservationIgnored private let sleepTimerDelay: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
    @ObservationIgnored private var preparedItemID: UUID?
    @ObservationIgnored private var pendingResolutionAutoplayItemID: UUID?
    @ObservationIgnored private var activePodcastLoadID: UUID?
    @ObservationIgnored private var activeYouTubeLoadID: UUID?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    /// Set once a sleep timer has paused playback, or left the next item
    /// paused at the end of one. Until something is played on purpose,
    /// items that replace the paused one, for example after a failure or
    /// when another device finishes it, are left paused too.
    @ObservationIgnored private var sleepTimerHoldsPlayback = false
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []

    var currentItem: QueueItem? {
        queue.item(id: currentItemID)
    }

    var nativeVideoPlayer: AVPlayer? {
        podcastEngine.renderingPlayer
    }

    /// True while the play control should show progress instead of a glyph.
    var isWaitingForMedia: Bool {
        transportState == .loading || (transportState == .playing && isBuffering)
    }

    /// Whether Next has another item to move to.
    var hasNextItem: Bool {
        guard let item = currentItem else { return false }
        return nextUnplayedItem(after: item) != nil
    }

    init(
        queue: QueueStore,
        podcastEngine: PodcastPlaybackEngine? = nil,
        youtubePlayer: YouTubePlayerModel? = nil,
        audioSession: AVAudioSession? = nil,
        sleepTimerDelay: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        let podcastEngine = podcastEngine ?? AVPlayerPodcastEngine()
        let youtubePlayer = youtubePlayer ?? YouTubePlayerModel()
        self.queue = queue
        self.podcastEngine = podcastEngine
        self.youtubePlayer = youtubePlayer
        self.audioSession = audioSession ?? .sharedInstance()
        self.sleepTimerDelay = sleepTimerDelay

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
        sleepTimerHoldsPlayback = false
        // Playing on purpose supersedes an interruption's pending resume.
        wasPlayingBeforeInterruption = false
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

        // A social video's signed link expires within minutes, so one paused
        // for longer (e.g. left ready by the sleep timer overnight) goes back
        // through start(), which refreshes the link, rather than resuming.
        // One that is still playing already has its media and carries on.
        guard preparedItemID == item.id,
              transportState.isPlaying || !item.playbackURLNeedsRefresh()
        else {
            start(item)
            return
        }

        switch item.source {
        case .podcast, .socialVideo:
            // A notice about why playback paused is stale once it resumes;
            // clear it first, so a problem activating audio still shows.
            notice = nil
            activateAudioSession()
            podcastEngine.play()
            isBuffering = !podcastEngine.isPlaying
            if item.source.isVideo {
                queue.recordPlaybackStarted(for: item)
            }
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
        if autoplay {
            sleepTimerHoldsPlayback = false
        }
        let isSwitchingItems = item.id != currentItemID
        saveCurrentProgress(force: true)
        let currentUsesNativePlayback =
            currentItem.map { $0.source != .youtube } ?? false
        let canKeepPodcastSession =
            currentUsesNativePlayback
            && item.source != .youtube
            && item.status == .ready
        let shouldDeactivatePodcastSession =
            currentUsesNativePlayback
            && !canKeepPodcastSession
        parkCurrentTransport(
            deactivateAudioSession: shouldDeactivatePodcastSession
        )
        notice = sleepTimerHoldsPlayback ? Self.sleepTimerNotice : nil
        isBuffering = false
        currentItemID = item.id
        preparedItemID = nil
        pendingResolutionAutoplayItemID = nil
        if item.isPlayed {
            queue.markUnplayed(item)
        }
        if isSwitchingItems {
            // Up Next plays top to bottom, so the playing item leads it.
            queue.moveToTopOfUpNext(item)
        }
        position = item.playbackPosition
        duration = item.duration
        playbackRate = item.playbackRate > 0 ? item.playbackRate : 1
        if item.source == .podcast {
            item.lastPlayedAt = Date()
        }
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

        if item.playbackURLNeedsRefresh() {
            if autoplay {
                pendingResolutionAutoplayItemID = item.id
            }
            transportState = .loading
            notice = "Refreshing the video link…"
            Task { [weak self] in
                await self?.queue.refreshPlaybackURL(for: item)
            }
            return
        }

        switch item.source {
        case .podcast, .socialVideo:
            startNativePlayback(item, autoplay: autoplay)
        case .youtube:
            startYouTube(item, autoplay: autoplay)
        }
    }

    func pause() {
        pendingResolutionAutoplayItemID = nil
        isBuffering = false
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
        case .podcast, .socialVideo:
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
        case .podcast, .socialVideo:
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
        case .podcast, .socialVideo:
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
        guard let next = nextUnplayedItem(after: item) else {
            saveCurrentProgress(force: true)
            finishQueue(notice: "This item remains in Up Next.")
            return
        }
        // A skipped item keeps its progress and waits at the end of Up Next.
        queue.moveToEndOfUpNext(item)
        start(next)
    }

    func markCurrentPlayed() {
        guard let item = currentItem else { return }
        queue.markPlayed(item)
        advance(from: item)
    }

    /// Pauses playback after `minutes`, whichever item is playing then.
    func setSleepTimer(minutes: Int, now: Date = Date()) {
        let delay = TimeInterval(minutes * 60)
        sleepTimerTask?.cancel()
        sleepTimer = .until(now.addingTimeInterval(delay))
        let wait = sleepTimerDelay
        sleepTimerTask = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.sleepTimerDidFire()
        }
    }

    /// Pauses when the current item finishes, leaving the next one ready.
    func setSleepTimerAtEndOfItem() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimer = .endOfItem
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimer = .off
    }

    private func sleepTimerDidFire() {
        sleepTimerTask = nil
        sleepTimer = .off
        // Audio paused by an interruption, such as a call, would resume when
        // the interruption ends; the timer cancels that resume too.
        let wouldResumeAfterInterruption = wasPlayingBeforeInterruption
        wasPlayingBeforeInterruption = false
        guard currentItem != nil,
              transportState.isPlaying
                || transportState == .loading
                || wouldResumeAfterInterruption
        else {
            return
        }
        pause()
        sleepTimerHoldsPlayback = true
        notice = Self.sleepTimerNotice
    }

    private static let sleepTimerNotice = "Paused by the sleep timer."

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
        isBuffering = false
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
        isBuffering = false
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
            isBuffering = false
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
            item.isPlayed = false
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
            case .podcast, .socialVideo:
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

    private func startNativePlayback(_ item: QueueItem, autoplay: Bool) {
        guard let url = item.playbackURL else {
            let mediaName = item.source == .socialVideo ? "video" : "podcast audio"
            queue.markUnavailable(item, reason: "The \(mediaName) URL is missing.")
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
            isBuffering = !podcastEngine.isPlaying
            if item.source.isVideo {
                queue.recordPlaybackStarted(for: item)
            }
            transportState = .playing
        } else {
            isBuffering = false
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
              item.source != .youtube
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
        case let .bufferingChanged(isWaiting):
            if transportState == .playing {
                isBuffering = isWaiting
            }
        case .ended:
            activePodcastLoadID = nil
            completeItem(item)
        case let .stalled(message):
            activePodcastLoadID = nil
            preparedItemID = nil
            isBuffering = false
            transportState = .needsUserAction
            notice = "\(message) Tap Play to retry."
            saveCurrentProgress(force: true)
            updateNowPlaying()
        case let .failed(message):
            activePodcastLoadID = nil
            queue.markUnavailable(item, reason: message)
            notice = item.source == .socialVideo
                ? "Skipped an unavailable social video."
                : "Skipped an unavailable podcast episode."
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
            // Includes the user starting the video in the player itself.
            sleepTimerHoldsPlayback = false
            queue.recordPlaybackStarted(for: item)
            isBuffering = false
            transportState = .playing
            notice = nil
        case .buffering:
            if transportState == .playing {
                isBuffering = true
            }
        case .paused:
            isBuffering = false
            if transportState == .playing || transportState == .loading {
                transportState = .paused
            }
            saveCurrentProgress(force: true)
        case .ended:
            activeYouTubeLoadID = nil
            completeItem(item)
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
            isBuffering = false
            transportState = .needsUserAction
            notice = "Tap Play to start this YouTube video."
        case let .failed(code):
            isBuffering = false
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
            // A refresh that couldn't reach the resolver, e.g. offline,
            // leaves the video ready with its old link. Starting it again
            // would only refresh again, so wait for the user to retry.
            guard !item.playbackURLNeedsRefresh() else {
                transportState = .needsUserAction
                notice = "Couldn’t refresh the video link. Tap Play to try again."
                return
            }
            start(item, autoplay: shouldAutoplay)
        } else if item.status == .unavailable {
            advanceAfterFailure()
        }
    }

    /// Moves on from `item` to the next item, or finishes the queue. While
    /// a sleep timer holds playback, the next item is left paused and shows
    /// the timer's notice.
    private func advance(from item: QueueItem) {
        guard let next = nextUnplayedItem(after: item) else {
            finishQueue()
            return
        }
        start(next, autoplay: !sleepTimerHoldsPlayback)
        if sleepTimerHoldsPlayback {
            notice = Self.sleepTimerNotice
        }
    }

    /// Handles a player's terminal event for `item`.
    private func completeItem(_ item: QueueItem) {
        queue.markPlayed(item)
        if sleepTimer == .endOfItem {
            sleepTimer = .off
            sleepTimerHoldsPlayback = true
        }
        advance(from: item)
    }

    private func advanceAfterFailure() {
        guard let item = currentItem else {
            finishQueue()
            return
        }
        advance(from: item)
    }

    /// The playing item leads Up Next, so the next one is the first
    /// playable item other than it.
    private func nextUnplayedItem(after item: QueueItem) -> QueueItem? {
        queue.firstUnplayed(excluding: item.id)
    }

    private func finishQueue(notice finalNotice: String = "Queue finished.") {
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
        sleepTimerHoldsPlayback = false
        activePodcastLoadID = nil
        activeYouTubeLoadID = nil
        transportState = .idle
        isBuffering = false
        position = 0
        duration = 0
        cancelSleepTimer()
        clearNowPlaying()
        notice = finalNotice
    }

    private func parkCurrentTransport(
        deactivateAudioSession: Bool = false
    ) {
        podcastEngine.pause()
        youtubePlayer.pause()
        activePodcastLoadID = nil
        activeYouTubeLoadID = nil
        isBuffering = false
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
                    guard let self, self.currentItem?.source != .youtube else {
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
        guard let item = currentItem, item.source != .youtube else {
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
            MPNowPlayingInfoPropertyMediaType:
                item.source == .socialVideo
                ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue
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
