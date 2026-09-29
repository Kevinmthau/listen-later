import SwiftUI

/// Colour tokens from the asset catalog. Each has light and dark appearances,
/// so views should use these rather than literal colours.
enum Palette {
    /// Text and symbols drawn on an accent-coloured fill: white on the dark
    /// light-mode accent, dark ink on the lighter dark-mode accent.
    static let onAccent = Color("AccentForeground")

    /// Row background for the item that is playing. Lighter than the normal
    /// row colour in both appearances, so it never reads as a disabled row.
    static let playingRow = Color("PlayingRowBackground")
}
