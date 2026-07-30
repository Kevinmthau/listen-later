import Foundation
import Observation
import WebKit

enum YouTubePlayerEvent: Equatable {
    case ready
    case playing
    case paused
    case ended
    case progress(position: TimeInterval, duration: TimeInterval)
    case playbackRateChanged(Double)
    case autoplayBlocked
    case failed(code: Int)
}

@MainActor
@Observable
final class YouTubePlayerModel {
    var videoID: String?
    var isReady = false
    var isPlaying = false
    var requiresUserAction = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    @ObservationIgnored var eventHandler: ((UUID, YouTubePlayerEvent) -> Void)?
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var desiredPosition: TimeInterval = 0
    @ObservationIgnored private var desiredAutoplay = false
    @ObservationIgnored private var desiredPlaybackRate: Double = 1
    @ObservationIgnored private var activeLoadID: UUID?

    func attach(webView: WKWebView) {
        if self.webView !== webView {
            isReady = false
        }
        self.webView = webView
    }

    func load(
        videoID: String,
        position: TimeInterval,
        autoplay: Bool,
        playbackRate: Double,
        loadID: UUID
    ) {
        self.videoID = videoID
        activeLoadID = loadID
        isPlaying = false
        requiresUserAction = false
        currentTime = position
        desiredPosition = position
        desiredAutoplay = autoplay
        desiredPlaybackRate = playbackRate

        if isReady {
            sendLoadCommand()
        }
    }

    private func sendLoadCommand() {
        guard let videoID else { return }
        let payload: [String: Any] = [
            "videoId": videoID,
            "startSeconds": max(0, desiredPosition),
            "autoplay": desiredAutoplay,
            "playbackRate": desiredPlaybackRate,
            "loadId": activeLoadID?.uuidString ?? ""
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("window.listenLater.load(\(json));")
    }

    func play() {
        requiresUserAction = false
        desiredAutoplay = true
        guard isReady else { return }
        evaluate("window.listenLater.play();")
    }

    func pause() {
        desiredAutoplay = false
        evaluate("window.listenLater.pause();")
    }

    func seek(to time: TimeInterval) {
        let position = max(0, time)
        desiredPosition = position
        currentTime = position
        evaluate("window.listenLater.seek(\(position));")
    }

    func setPlaybackRate(_ rate: Double) {
        desiredPlaybackRate = rate
        evaluate("window.listenLater.setRate(\(rate));")
    }

    func receive(
        _ event: YouTubePlayerEvent,
        loadID: UUID?,
        videoID eventVideoID: String?
    ) {
        if event == .ready {
            isReady = true
            sendLoadCommand()
            return
        }

        guard let loadID,
              loadID == activeLoadID,
              eventVideoID == videoID
        else {
            return
        }

        switch event {
        case .ready:
            break
        case .playing:
            isPlaying = true
            requiresUserAction = false
            setPlaybackRate(desiredPlaybackRate)
        case .paused:
            isPlaying = false
        case .ended:
            isPlaying = false
        case let .progress(position, duration):
            currentTime = position
            desiredPosition = position
            self.duration = duration
        case let .playbackRateChanged(rate):
            desiredPlaybackRate = rate
        case .autoplayBlocked:
            isPlaying = false
            requiresUserAction = true
        case .failed:
            isPlaying = false
        }
        eventHandler?(loadID, event)
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script)
    }
}
