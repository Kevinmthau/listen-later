import Foundation

/// Playback settings the user can change in Settings.
enum PlaybackPreferences {
    static let clipsPlayContinuouslyKey = "clipsPlayContinuously"
    /// The setting this replaced, "Save Videos for the Screen": the inverse
    /// of continuous play. A choice made under it is carried over by
    /// `migrate()`.
    static let legacyVideosWaitForScreenKey = "videosWaitForScreen"

    /// While MushRadio is in the background (screen locked or another app
    /// open), automatic advances play X and Instagram clips too, as audio,
    /// one after another like podcasts. Off, those advances play only audio
    /// and leave clips in Up Next for when the user can watch them. On
    /// unless the user turns it off.
    static func clipsPlayContinuously(in defaults: UserDefaults = .standard) -> Bool {
        if let stored = defaults.object(forKey: clipsPlayContinuouslyKey) as? Bool {
            return stored
        }
        if let heldVideos = defaults.object(forKey: legacyVideosWaitForScreenKey) as? Bool {
            return !heldVideos
        }
        return true
    }

    /// Whether automatic advances made in the background leave videos in Up
    /// Next; what the player's on-screen rule reads.
    static var videosWaitForScreen: Bool {
        !clipsPlayContinuously()
    }

    /// Moves a choice made under the old "Save Videos for the Screen"
    /// setting to the current key, so Settings shows it. A value already
    /// stored under the current key wins.
    static func migrate(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: clipsPlayContinuouslyKey) == nil,
              let heldVideos = defaults.object(forKey: legacyVideosWaitForScreenKey) as? Bool
        else {
            return
        }
        defaults.set(!heldVideos, forKey: clipsPlayContinuouslyKey)
        defaults.removeObject(forKey: legacyVideosWaitForScreenKey)
    }
}
