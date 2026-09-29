import AVKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The queue stays portrait on iPhone; the full-screen video player may
    /// rotate. Deriving this from what is on screen means closing the
    /// player returns the app to portrait with no state to reset.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller is AVPlayerViewController ? .allButUpsideDown : .portrait
    }
}
