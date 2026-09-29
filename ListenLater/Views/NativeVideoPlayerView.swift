import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct NativeVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    /// Called with the video's natural size once it is known.
    var onVideoSizeChange: (CGSize) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.onVideoSizeChange = onVideoSizeChange
        view.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.onVideoSizeChange = onVideoSizeChange
        view.player = player
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var onVideoSizeChange: (CGSize) -> Void = { _ in }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard newValue !== playerLayer.player else { return }
            playerLayer.player = newValue
            observeVideoSize()
        }
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    private var sizeObservation: NSKeyValueObservation?
    private var pictureInPicture: AVPictureInPictureController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        isAccessibilityElement = true
        accessibilityLabel = "Video"
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fullScreenVideoDidEnd),
            name: .fullScreenVideoDidEnd,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Leaving the app while a video plays continues it in Picture in
        // Picture, so it isn't lost to background audio.
        guard window != nil,
              pictureInPicture == nil,
              AVPictureInPictureController.isPictureInPictureSupported()
        else {
            return
        }
        pictureInPicture = AVPictureInPictureController(playerLayer: playerLayer)
        pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    /// The full-screen player shares this AVPlayer; attach it here again so
    /// the inline surface shows video after the full-screen one closes.
    @objc private func fullScreenVideoDidEnd() {
        let current = playerLayer.player
        playerLayer.player = nil
        playerLayer.player = current
    }

    private func observeVideoSize() {
        sizeObservation = playerLayer.player?.observe(
            \.currentItem?.presentationSize,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            let size = player.currentItem?.presentationSize ?? .zero
            Task { @MainActor in
                self?.onVideoSizeChange(size)
            }
        }
    }
}
