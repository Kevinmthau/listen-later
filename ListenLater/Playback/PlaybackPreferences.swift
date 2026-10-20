import Foundation

/// Playback settings the user can change in Settings.
enum PlaybackPreferences {
    static let clipsPlayContinuouslyKey = "clipsPlayContinuously"
    /// The setting this replaced, "Save Videos for the Screen": the inverse
    /// of continuous play. A choice made under it is carried over by
    /// `migrate()`.
    static let legacyVideosWaitForScreenKey = "videosWaitForScreen"

    /// While MushRadio is in the background (screen locked or another app
    /// open), a playing clip carries on as audio, and automatic advances
    /// play X and Instagram clips too, one after another like podcasts.
    /// Off, the system pauses a clip nobody can see, and those advances
    /// play only audio and leave clips in Up Next for when the user can
    /// watch them. On unless the user turns it off.
    static func clipsPlayContinuously(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: clipsPlayContinuouslyKey) as? Bool ?? true
    }

    /// Copies a choice made under the old "Save Videos for the Screen"
    /// setting to the current key, so Settings and every reader see it. Runs
    /// before anything reads the setting. A value already stored under the
    /// current key wins. The old key is left in place so an earlier build
    /// still finds the choice.
    static func migrate(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: clipsPlayContinuouslyKey) == nil,
              let heldVideos = defaults.object(forKey: legacyVideosWaitForScreenKey) as? Bool
        else {
            return
        }
        defaults.set(!heldVideos, forKey: clipsPlayContinuouslyKey)
    }
}
