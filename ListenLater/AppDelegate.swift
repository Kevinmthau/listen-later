import AVKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let processInfo = ProcessInfo.processInfo
        let usesInMemoryStore = processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processInfo.arguments.contains("-DemoQueue")
            || processInfo.arguments.contains("-InMemoryStore")
        if !usesInMemoryStore {
            // SwiftData's CloudKit store consumes silent notifications to import
            // remote changes. Registration does not request alert permission.
            application.registerForRemoteNotifications()
        }
        return true
    }

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
        while let presented = controller?.presentedViewController,
              !presented.isBeingDismissed {
            controller = presented
        }
        return controller is AVPlayerViewController ? .allButUpsideDown : .portrait
    }
}
