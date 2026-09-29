import Foundation

/// Playback settings the user can change in Settings.
enum PlaybackPreferences {
    static let videosWaitForScreenKey = "videosWaitForScreen"

    /// While MushRadio is in the background (screen locked or another app
    /// open), automatic advances play only audio and leave videos in Up Next
    /// for when the user can watch them. On unless the user turns it off.
    static var videosWaitForScreen: Bool {
        UserDefaults.standard.object(forKey: videosWaitForScreenKey) as? Bool ?? true
    }
}
