import Foundation

enum MediaSource: String, Codable, CaseIterable, Sendable {
    case podcast
    case youtube

    var displayName: String {
        switch self {
        case .podcast: "Podcast"
        case .youtube: "YouTube"
        }
    }

    var symbolName: String {
        switch self {
        case .podcast: "dot.radiowaves.left.and.right"
        case .youtube: "play.rectangle.fill"
        }
    }
}

enum QueueItemStatus: String, Codable, Sendable {
    case resolving
    case ready
    case unavailable
}

