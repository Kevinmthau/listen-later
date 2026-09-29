import SwiftUI

/// Colour tokens. The accent and surfaces come from the asset catalog and
/// have light and dark appearances; the artwork gradients are fixed, like
/// real artwork. Views should use these rather than literal colours.
/// `Design/README.md` lists the values and their contrast ratios.
enum Palette {
    /// Text and symbols drawn on an accent-coloured fill: white on the
    /// light-mode walnut, dark ink on the dark-mode brass.
    static let onAccent = Color("AccentForeground")

    /// Row background for the item that is playing: a warm tint of the row
    /// colour, lighter than the normal row in dark mode so it never reads as
    /// a disabled row.
    static let playingRow = Color("PlayingRowBackground")

    /// The light-mode accent, in both appearances. For controls that draw
    /// their own white label, such as `PasteButton`, where white on the
    /// dark-mode brass would measure only 2.1:1.
    static let walnut = Color(hex: 0x7A3E1D)

    /// Stands in for artwork that is missing or still loading, in the icon's
    /// woods and brass. White symbols stay above 3:1 across each gradient.
    static func artworkGradient(for source: MediaSource) -> [Color] {
        switch source {
        case .podcast:
            [Color(hex: 0x6B3419), Color(hex: 0xC0823F)]
        case .socialVideo:
            [Color(hex: 0x1F1A17), Color(hex: 0x5B4636)]
        case .youtube:
            [Color(hex: 0x6E1B14), Color(hex: 0xC0392B)]
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
