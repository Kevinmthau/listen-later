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
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
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
            NotificationCenter.default.post(name: .fullScreenVideoDidEnd, object: nil)
        }
    }
}
