import AVKit
import UIKit

extension Notification.Name {
    /// Posted after the full-screen video player closes.
    static let fullScreenVideoDidEnd = Notification.Name("FullScreenVideoDidEnd")
}

/// Presents the system player full screen for the app's shared AVPlayer,
/// with its own close button, Picture in Picture and AirPlay. AppDelegate
/// lets it rotate while the rest of the app stays portrait on iPhone.
@MainActor
enum FullScreenVideo {
    private static let delegate = FullScreenVideoDelegate()
    private static weak var presented: AVPlayerViewController?

    static func present(_ player: AVPlayer) {
        guard let presenter = topViewController(),
              !(presenter is AVPlayerViewController)
        else {
            return
        }
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = delegate
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // The coordinator owns Now Playing and the remote commands.
        controller.updatesNowPlayingInfoCenter = false
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
        presented = controller
    }

    /// Closes the full-screen player, e.g. when the queue moves on to
    /// something that isn't a native video.
    static func dismiss() {
        guard let controller = presented, !controller.isBeingDismissed else { return }
        controller.dismiss(animated: true) {
            didEnd()
        }
    }

    /// The inline player takes the video back, and the app returns to
    /// portrait on iPhone now that no player allows landscape.
    fileprivate static func didEnd() {
        NotificationCenter.default.post(name: .fullScreenVideoDidEnd, object: nil)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

private final class FullScreenVideoDelegate: NSObject, AVPlayerViewControllerDelegate {
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        _ = coordinator.animate(alongsideTransition: nil) { context in
            guard !context.isCancelled else { return }
            MainActor.assumeIsolated {
                FullScreenVideo.didEnd()
            }
        }
    }
}
