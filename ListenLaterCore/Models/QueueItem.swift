import Foundation
import SwiftData

@Model
final class QueueItem {
    var id: UUID = UUID()
    var originalURLString: String = ""
    var canonicalURLString: String = ""
    var playbackURLString: String?
    var playbackURLExpiresAt: Date?
    var youtubeVideoID: String?
    var pendingShareReceiptIDString: String?

    var title: String = "Untitled"
    var subtitle: String = ""
    var artworkURLString: String?
    var duration: TimeInterval = 0
    var sourceRawValue: String = MediaSource.podcast.rawValue
    var statusRawValue: String = QueueItemStatus.resolving.rawValue
    var unavailableReason: String?
    var metadataFetchedAt: Date?
    var youtubeEmbeddable: Bool = true
    var youtubeMadeForKids: Bool = false

    var sortRank: Double = 0
    var playbackPosition: TimeInterval = 0
    var playbackRate: Double = 1
    var isPlayed: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var progressUpdatedAt: Date = Date.distantPast
    var lastPlayedAt: Date?

    init(
        id: UUID = UUID(),
        originalURL: URL,
        canonicalURL: URL? = nil,
        title: String = "Resolving…",
        subtitle: String = "",
        source: MediaSource,
        status: QueueItemStatus = .resolving,
        sortRank: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        originalURLString = originalURL.absoluteString
        canonicalURLString = (canonicalURL ?? originalURL).absoluteString
        self.title = title
        self.subtitle = subtitle
        sourceRawValue = source.rawValue
        statusRawValue = status.rawValue
        self.sortRank = sortRank
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var originalURL: URL? {
        URL(string: originalURLString)
    }

    var canonicalURL: URL? {
        URL(string: canonicalURLString)
    }

    var playbackURL: URL? {
        playbackURLString.flatMap(URL.init(string:))
    }

    var artworkURL: URL? {
        artworkURLString.flatMap(URL.init(string:))
    }

    func playbackURLNeedsRefresh(
        at date: Date = Date(),
        safetyWindow: TimeInterval = 30
    ) -> Bool {
        guard source == .socialVideo else { return false }
        guard playbackURL != nil, let playbackURLExpiresAt else { return true }
        return playbackURLExpiresAt <= date.addingTimeInterval(safetyWindow)
    }

    var source: MediaSource {
        get { MediaSource(rawValue: sourceRawValue) ?? .podcast }
        set { sourceRawValue = newValue.rawValue }
    }

    var status: QueueItemStatus {
        get { QueueItemStatus(rawValue: statusRawValue) ?? .resolving }
        set { statusRawValue = newValue.rawValue }
    }

    var remainingDuration: TimeInterval {
        max(0, duration - playbackPosition)
    }

    var hasMeaningfulProgress: Bool {
        playbackPosition >= 3 && !isPlayed
    }
}
