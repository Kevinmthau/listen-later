import Foundation

enum MediaSource: String, Codable, CaseIterable, Sendable {
    case podcast
    case socialVideo
    case youtube

    var displayName: String {
        switch self {
        case .podcast: "Podcast"
        case .socialVideo: "Social Video"
        case .youtube: "YouTube"
        }
    }

    var symbolName: String {
        switch self {
        case .podcast: "dot.radiowaves.left.and.right"
        case .socialVideo: "play.square.stack.fill"
        case .youtube: "play.rectangle.fill"
        }
    }

    var isVideo: Bool {
        self != .podcast
    }
}

enum QueueItemStatus: String, Codable, Sendable {
    case resolving
    case ready
    case unavailable
}
