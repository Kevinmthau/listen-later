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

    /// The durable public page to send when sharing a video. Social-video
    /// playback URLs are intentionally excluded because they can expire.
    var videoShareURL: URL? {
        guard source.isVideo else { return nil }
        return canonicalURL ?? originalURL
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

    var isInPlayedSection: Bool {
        isPlayed
    }

    /// The name to show for where this came from, e.g. "X" or "Instagram"
    /// rather than the generic "Social Video".
    var sourceName: String {
        guard source == .socialVideo,
              let originalURL,
              let platform = SocialVideoURLParser.parse(originalURL)?.platform
        else {
            return source.displayName
        }
        return platform.displayName
    }

    func snapshot() -> QueueItemSnapshot {
        QueueItemSnapshot(
            id: id,
            originalURLString: originalURLString,
            canonicalURLString: canonicalURLString,
            playbackURLString: playbackURLString,
            playbackURLExpiresAt: playbackURLExpiresAt,
            youtubeVideoID: youtubeVideoID,
            pendingShareReceiptIDString: pendingShareReceiptIDString,
            title: title,
            subtitle: subtitle,
            artworkURLString: artworkURLString,
            duration: duration,
            sourceRawValue: sourceRawValue,
            statusRawValue: statusRawValue,
            unavailableReason: unavailableReason,
            metadataFetchedAt: metadataFetchedAt,
            youtubeEmbeddable: youtubeEmbeddable,
            youtubeMadeForKids: youtubeMadeForKids,
            sortRank: sortRank,
            playbackPosition: playbackPosition,
            playbackRate: playbackRate,
            isPlayed: isPlayed,
            createdAt: createdAt,
            updatedAt: updatedAt,
            progressUpdatedAt: progressUpdatedAt,
            lastPlayedAt: lastPlayedAt
        )
    }
}

/// Every stored value of a deleted `QueueItem`, so Undo can recreate it.
struct QueueItemSnapshot: Sendable {
    let id: UUID
    let originalURLString: String
    let canonicalURLString: String
    let playbackURLString: String?
    let playbackURLExpiresAt: Date?
    let youtubeVideoID: String?
    let pendingShareReceiptIDString: String?
    let title: String
    let subtitle: String
    let artworkURLString: String?
    let duration: TimeInterval
    let sourceRawValue: String
    let statusRawValue: String
    let unavailableReason: String?
    let metadataFetchedAt: Date?
    let youtubeEmbeddable: Bool
    let youtubeMadeForKids: Bool
    let sortRank: Double
    let playbackPosition: TimeInterval
    let playbackRate: Double
    let isPlayed: Bool
    let createdAt: Date
    let updatedAt: Date
    let progressUpdatedAt: Date
    let lastPlayedAt: Date?

    func makeItem() -> QueueItem? {
        guard let originalURL = URL(string: originalURLString) else { return nil }
        let item = QueueItem(
            id: id,
            originalURL: originalURL,
            title: title,
            subtitle: subtitle,
            source: MediaSource(rawValue: sourceRawValue) ?? .podcast,
            sortRank: sortRank,
            createdAt: createdAt
        )
        item.canonicalURLString = canonicalURLString
        item.playbackURLString = playbackURLString
        item.playbackURLExpiresAt = playbackURLExpiresAt
        item.youtubeVideoID = youtubeVideoID
        item.pendingShareReceiptIDString = pendingShareReceiptIDString
        item.artworkURLString = artworkURLString
        item.duration = duration
        item.statusRawValue = statusRawValue
        item.unavailableReason = unavailableReason
        item.metadataFetchedAt = metadataFetchedAt
        item.youtubeEmbeddable = youtubeEmbeddable
        item.youtubeMadeForKids = youtubeMadeForKids
        item.playbackPosition = playbackPosition
        item.playbackRate = playbackRate
        item.isPlayed = isPlayed
        item.updatedAt = Date()
        item.progressUpdatedAt = progressUpdatedAt
        item.lastPlayedAt = lastPlayedAt
        return item
    }
}
