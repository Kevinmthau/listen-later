import AVFoundation
import Foundation

enum AudioSessionInterruption: Equatable {
    case began
    case ended(shouldResume: Bool)
}

/// Keeps iOS audio-session policy and notification decoding out of the
/// platform-neutral playback state machine.
@MainActor
protocol AudioSessionAdapting: AnyObject {
    func configureForPlayback() throws
    func activate() throws
    func deactivate() throws
    func observe(
        interruption: @escaping @MainActor (AudioSessionInterruption) -> Void,
        outputRouteDisconnected: @escaping @MainActor () -> Void
    ) -> [NSObjectProtocol]
}

@MainActor
final class IOSAudioSessionAdapter: AudioSessionAdapting {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func configureForPlayback() throws {
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
    }

    func activate() throws {
        try session.setActive(true)
    }

    func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func observe(
        interruption: @escaping @MainActor (AudioSessionInterruption) -> Void,
        outputRouteDisconnected: @escaping @MainActor () -> Void
    ) -> [NSObjectProtocol] {
        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions =
                notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                ?? 0
            Task { @MainActor in
                guard
                    let rawType,
                    let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { return }

                switch type {
                case .began:
                    interruption(.began)
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    interruption(.ended(shouldResume: options.contains(.shouldResume)))
                @unknown default:
                    break
                }
            }
        }

        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard
                    let rawReason,
                    AVAudioSession.RouteChangeReason(rawValue: rawReason)
                        == .oldDeviceUnavailable
                else { return }
                outputRouteDisconnected()
            }
        }

        return [interruptionObserver, routeObserver]
    }
}
