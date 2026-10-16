import Foundation

enum MediaSource: String, Codable, CaseIterable, Sendable {
    case podcast
    case socialVideo
    case youtube
    case localVideo
    /// Preserves forward compatibility for source values written by a newer
    /// client. Unknown values must never be interpreted as podcasts.
    case unknown

    var displayName: String {
        switch self {
        case .podcast: "Podcast"
        case .socialVideo: "Social Video"
        case .youtube: "YouTube"
        case .localVideo: "Local Video"
        case .unknown: "Unsupported"
        }
    }

    var symbolName: String {
        switch self {
        case .podcast: "dot.radiowaves.left.and.right"
        case .socialVideo: "play.square.stack.fill"
        case .youtube: "play.rectangle.fill"
        case .localVideo: "film.fill"
        case .unknown: "questionmark.square.dashed"
        }
    }

    var isVideo: Bool {
        switch self {
        case .socialVideo, .youtube, .localVideo:
            true
        case .podcast, .unknown:
            false
        }
    }
}

enum QueueItemStatus: String, Codable, Sendable {
    case resolving
    case ready
    case unavailable
}
