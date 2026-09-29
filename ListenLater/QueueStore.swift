import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class QueueStore {
    private(set) var items: [QueueItem] = []
    private(set) var isResolving = false
    var lastErrorMessage: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let providers: ProviderRegistry
    @ObservationIgnored private let inbox: SharedQueueInbox?
    @ObservationIgnored var resolutionHandler: ((QueueItem) -> Void)?
    @ObservationIgnored private var resolvingItemIDs: Set<UUID> = []
    @ObservationIgnored private var isImportingShares = false

    init(
        context: ModelContext,
        providers: ProviderRegistry,
        inbox: SharedQueueInbox? = nil
    ) {
        self.context = context
        self.providers = providers
        self.inbox = inbox
        refresh()
    }

    func refresh() {
        var descriptor = FetchDescriptor<QueueItem>()
        descriptor.includePendingChanges = true
        do {
            items = try context.fetch(descriptor).sorted {
                if $0.sortRank != $1.sortRank {
                    return $0.sortRank < $1.sortRank
                }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        } catch {
            lastErrorMessage = "Couldn’t load the queue: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func add(url: URL) async -> QueueItem? {
        guard let item = stage(url: url, pendingShareReceiptID: nil) else {
            return nil
        }
        let itemID = item.id
        await resolve(item)
        return self.item(id: itemID)
    }

    private func stage(
        url: URL,
        pendingShareReceiptID: UUID?
    ) -> QueueItem? {
        guard ProviderURLSupport.isHTTPURL(url) else {
            lastErrorMessage = "Only secure public HTTPS links are supported."
            return nil
        }

        if let existing = items.first(where: {
            queueItem($0, matches: url)
        }) {
            let wasPlayed = existing.isInPlayedSection
            existing.isPlayed = false
            if existing.source.isVideo {
                existing.lastPlayedAt = nil
            }
            if wasPlayed {
                existing.playbackPosition = 0
            }
            existing.status = .resolving
            existing.unavailableReason = nil
            existing.sortRank = nextRank()
            if let pendingShareReceiptID {
                existing.pendingShareReceiptIDString =
                    pendingShareReceiptID.uuidString
            }
            existing.updatedAt = Date()
            guard saveAndRefresh() else { return nil }
            return existing
        }

        let provider = providers.provider(for: url)
        let source = provider.map { mediaSource(for: $0.source) } ?? .podcast
        let placeholderTitle: String
        switch source {
        case .podcast:
            placeholderTitle = "Podcast episode"
        case .socialVideo:
            let platform = SocialVideoURLParser.parse(url)?.platform.displayName
            placeholderTitle = "\(platform ?? "Social") video"
        case .youtube:
            placeholderTitle = "YouTube video"
        }
        let item = QueueItem(
            originalURL: url,
            title: placeholderTitle,
            source: source,
            sortRank: nextRank()
        )
        item.pendingShareReceiptIDString = pendingShareReceiptID?.uuidString
        context.insert(item)
        guard saveAndRefresh() else { return nil }
        return item
    }

    func retry(_ item: QueueItem) async {
        item.status = .resolving
        item.unavailableReason = nil
        item.updatedAt = Date()
        saveAndRefresh()
        await resolve(item)
    }

    func refreshPlaybackURL(for item: QueueItem) async {
        guard item.source == .socialVideo,
              self.item(id: item.id) != nil
        else {
            return
        }
        item.status = .resolving
        item.unavailableReason = nil
        item.updatedAt = Date()
        guard saveAndRefresh() else { return }
        // Losing the connection mustn't cost a video its place in the queue.
        await resolve(item, preserveAvailabilityOnTransientFailure: true)
    }

    func importPendingShares() async {
        guard let inbox, !isImportingShares else { return }
        isImportingShares = true
        var itemsToResolve: [QueueItem] = []

        do {
            let batch = try inbox.pendingBatch()
            if batch.quarantinedFileCount > 0 {
                let count = batch.quarantinedFileCount
                lastErrorMessage =
                    "\(count) damaged shared-link file\(count == 1 ? " was" : "s were") moved aside."
            }
            for receipt in batch.receipts {
                guard ProviderURLSupport.isHTTPURL(receipt.share.url) else {
                    do {
                        try inbox.acknowledge(receipt)
                        lastErrorMessage =
                            "Ignored a shared link that was not a secure public HTTPS URL."
                    } catch {
                        lastErrorMessage =
                            "Couldn’t discard an invalid shared link: \(error.localizedDescription)"
                        break
                    }
                    continue
                }

                let receiptID = receipt.id.uuidString
                if let existing = items.first(where: {
                    $0.pendingShareReceiptIDString == receiptID
                }) {
                    do {
                        try inbox.acknowledge(receipt)
                    } catch {
                        lastErrorMessage =
                            "Couldn’t acknowledge an imported link: \(error.localizedDescription)"
                        break
                    }
                    if existing.status == .resolving {
                        itemsToResolve.append(existing)
                    }
                    continue
                }

                guard let item = stage(
                    url: receipt.share.url,
                    pendingShareReceiptID: receipt.id
                ) else { break }

                // Once the resolving QueueItem and its receipt ID are durable,
                // the App Group file can be consumed. A termination after this
                // point is recovered by resumePendingResolutions() without
                // staging or reordering the item a second time.
                do {
                    try inbox.acknowledge(receipt)
                } catch {
                    lastErrorMessage =
                        "Couldn’t acknowledge an imported link: \(error.localizedDescription)"
                    itemsToResolve.append(item)
                    break
                }
                itemsToResolve.append(item)
            }
        } catch {
            lastErrorMessage = "Couldn’t import shared links: \(error.localizedDescription)"
        }

        // Release the inbox staging lock before network work. A new Share
        // Extension receipt can then be durably staged even if an earlier
        // provider is slow; resolvingItemIDs suppresses duplicate resolution.
        isImportingShares = false
        var scheduledIDs: Set<UUID> = []
        for item in itemsToResolve where scheduledIDs.insert(item.id).inserted {
            if item.status == .resolving {
                await resolve(item)
            }
        }
    }

    func resumePendingResolutions() async {
        let pending = items.filter { $0.status == .resolving }
        for item in pending where item.status == .resolving {
            await resolve(item)
        }
    }

    func refreshExpiredYouTubeMetadata(now: Date = Date()) async {
        let expiration = now.addingTimeInterval(-29 * 24 * 60 * 60)
        let policyExpiration = now.addingTimeInterval(-30 * 24 * 60 * 60)

        // An unavailable item has already failed terminal resolution. Retrying
        // it on every activation wastes quota, but any retained API metadata
        // still has to be removed once it reaches the policy deadline.
        let unavailableExpired = items.filter {
            $0.source == .youtube
                && $0.status == .unavailable
                && $0.metadataFetchedAt.map { $0 <= policyExpiration } == true
        }
        for item in unavailableExpired {
            purgeExpiredYouTubeMetadata(item)
        }

        let stale = items.filter {
            $0.source == .youtube
                && $0.status == .ready
                && ($0.metadataFetchedAt == nil || $0.metadataFetchedAt! < expiration)
        }
        for item in stale {
            await resolve(item, preserveAvailabilityOnTransientFailure: true)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        var reordered = items
        let moving = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = min(
            max(0, destination - removedBeforeDestination),
            reordered.count
        )
        reordered.insert(contentsOf: moving, at: insertionIndex)
        applyRanks(to: reordered)
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        var reorderedUpNext = items.filter { !$0.isInPlayedSection }
        let moving = source.sorted().map { reorderedUpNext[$0] }
        for index in source.sorted(by: >) {
            reorderedUpNext.remove(at: index)
        }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = min(
            max(0, destination - removedBeforeDestination),
            reorderedUpNext.count
        )
        reorderedUpNext.insert(contentsOf: moving, at: insertionIndex)

        var upNextIterator = reorderedUpNext.makeIterator()
        let reordered = items.compactMap { item in
            item.isInPlayedSection ? item : upNextIterator.next()
        }
        applyRanks(to: reordered)
    }

    /// Puts `item` ahead of every other Up Next item. Up Next plays top to
    /// bottom, so the item being played leads it. No-op when it already does,
    /// so automatic advances don't rewrite ranks.
    func moveToTopOfUpNext(_ item: QueueItem) {
        let upNext = items.filter { !$0.isInPlayedSection }
        guard let first = upNext.first, first.id != item.id else { return }
        var reordered = items.filter { $0.id != item.id }
        let insertionIndex = reordered.firstIndex { $0.id == first.id } ?? 0
        reordered.insert(item, at: insertionIndex)
        applyRanks(to: reordered)
    }

    /// Puts `item` after every other Up Next item, e.g. when it is skipped.
    func moveToEndOfUpNext(_ item: QueueItem) {
        let upNext = items.filter { !$0.isInPlayedSection }
        guard let last = upNext.last, last.id != item.id else { return }
        var reordered = items.filter { $0.id != item.id }
        let lastIndex = reordered.firstIndex { $0.id == last.id }
            ?? reordered.index(before: reordered.endIndex)
        reordered.insert(item, at: lastIndex + 1)
        applyRanks(to: reordered)
    }

    func moveToPlayNext(_ item: QueueItem, after currentID: UUID?) {
        guard item.id != currentID else { return }
        var reordered = items.filter { $0.id != item.id }
        let insertionIndex: Int
        if
            let currentID,
            let currentIndex = reordered.firstIndex(where: { $0.id == currentID })
        {
            insertionIndex = currentIndex + 1
        } else {
            insertionIndex = 0
        }
        reordered.insert(item, at: min(insertionIndex, reordered.count))
        applyRanks(to: reordered)
    }

    /// Deletes `item` and returns what Undo needs to recreate it. Other
    /// items keep their ranks, so a restored item returns to its place.
    @discardableResult
    func delete(_ item: QueueItem) -> QueueItemSnapshot? {
        delete([item]).first
    }

    @discardableResult
    func delete(_ itemsToDelete: [QueueItem]) -> [QueueItemSnapshot] {
        guard !itemsToDelete.isEmpty else { return [] }
        let snapshots = itemsToDelete.map { $0.snapshot() }
        for item in itemsToDelete {
            evictArtworkCache(for: item)
            context.delete(item)
        }
        guard saveAndRefresh() else { return [] }
        return snapshots
    }

    /// Recreates deleted items with their original ranks and progress.
    func restore(_ snapshots: [QueueItemSnapshot]) {
        var restored: [QueueItem] = []
        for snapshot in snapshots where item(id: snapshot.id) == nil {
            guard let item = snapshot.makeItem() else { continue }
            context.insert(item)
            restored.append(item)
        }
        guard !restored.isEmpty, saveAndRefresh() else { return }
        // A lookup that finished while its item was deleted was discarded,
        // so look up restored items that are still pending. One still in
        // flight isn't started twice, and applies to the restored item.
        for item in restored where item.status == .resolving {
            Task { [weak self] in
                await self?.resolve(item)
            }
        }
    }

    func markPlayed(_ item: QueueItem) {
        item.isPlayed = true
        item.lastPlayedAt = Date()
        if item.source != .youtube, item.duration > 0 {
            item.playbackPosition = item.duration
        }
        item.updatedAt = Date()
        item.progressUpdatedAt = Date()
        saveAndRefresh()
    }

    func markUnplayed(_ item: QueueItem) {
        item.isPlayed = false
        item.lastPlayedAt = nil
        item.playbackPosition = 0
        item.updatedAt = Date()
        item.progressUpdatedAt = Date()
        saveAndRefresh()
    }

    func recordPlaybackStarted(for item: QueueItem) {
        guard item.source.isVideo else { return }
        item.lastPlayedAt = Date()
        item.updatedAt = Date()
        saveAndRefresh()
    }

    func markUnavailable(_ item: QueueItem, reason: String) {
        item.status = .unavailable
        item.unavailableReason = reason
        item.updatedAt = Date()
        saveAndRefresh()
    }

    func saveProgress(
        for item: QueueItem,
        position: TimeInterval,
        duration: TimeInterval? = nil,
        rate: Double? = nil,
        now: Date = Date(),
        force: Bool = false
    ) {
        let normalizedPosition = max(0, position)
        let positionChanged = abs(item.playbackPosition - normalizedPosition) >= 0.25
        let durationChanged = duration.map {
            $0.isFinite && $0 > 0 && abs(item.duration - $0) >= 0.25
        } ?? false
        let rateChanged = rate.map {
            abs(item.playbackRate - $0) >= 0.001
        } ?? false

        guard force || positionChanged || durationChanged || rateChanged else { return }
        guard force || now.timeIntervalSince(item.progressUpdatedAt) >= 5 else { return }

        item.playbackPosition = normalizedPosition
        if let duration, duration.isFinite, duration > 0 {
            item.duration = duration
        }
        if let rate {
            item.playbackRate = rate
        }
        // Only a terminal player event or an explicit user action establishes
        // completion. A saved position, even at the known duration, is still
        // resumable progress until the player confirms that playback ended.
        item.progressUpdatedAt = now
        item.updatedAt = now
        do {
            try context.save()
            refresh()
        } catch {
            let message =
                "Couldn’t save playback progress: \(error.localizedDescription)"
            context.rollback()
            refresh()
            lastErrorMessage = message
        }
    }

    func firstUnplayed(excluding excludedID: UUID? = nil) -> QueueItem? {
        items.first {
            !$0.isInPlayedSection
                && $0.status != .unavailable
                && $0.id != excludedID
        }
    }

    func resumeCandidate() -> QueueItem? {
        items
            .filter {
                !$0.isPlayed
                    && $0.status == .ready
                    && $0.lastPlayedAt != nil
            }
            .max {
                ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast)
            }
    }

    func nextUnplayed(after item: QueueItem) -> QueueItem? {
        guard let currentIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return firstUnplayed()
        }
        return items.dropFirst(currentIndex + 1).first {
            !$0.isInPlayedSection && $0.status != .unavailable
        }
    }

    func item(id: UUID?) -> QueueItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func appendResolvedForTesting(_ resolved: ProviderResolvedItem) -> QueueItem {
        let source = mediaSource(for: resolved.source)
        let item = QueueItem(
            originalURL: resolved.originalURL,
            canonicalURL: resolved.canonicalURL,
            source: source,
            status: .ready,
            sortRank: nextRank()
        )
        context.insert(item)
        apply(resolved, to: item)
        saveAndRefresh()
        return item
    }

    func seedDemoDataIfNeeded() {
        guard items.isEmpty else { return }
        let now = Date()

        let first = QueueItem(
            originalURL: URL(string: "https://example.com/podcast/slow-technology")!,
            title: "The case for slower technology",
            subtitle: "Signals & Threads",
            source: .podcast,
            status: .ready,
            sortRank: 1_000,
            createdAt: now
        )
        first.duration = 3_248
        first.playbackPosition = 742
        first.playbackURLString = "https://example.com/audio/slow-technology.mp3"

        let second = QueueItem(
            originalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            title: "How a record becomes a memory",
            subtitle: "Field Notes",
            source: .youtube,
            status: .ready,
            sortRank: 2_000,
            createdAt: now.addingTimeInterval(1)
        )
        second.duration = 1_106
        second.youtubeVideoID = "dQw4w9WgXcQ"
        second.metadataFetchedAt = now

        let third = QueueItem(
            originalURL: URL(string: "https://example.com/podcast/designing-calm")!,
            title: "Designing for calm",
            subtitle: "Good Objects",
            source: .podcast,
            status: .ready,
            sortRank: 3_000,
            createdAt: now.addingTimeInterval(2)
        )
        third.duration = 2_681

        context.insert(first)
        context.insert(second)
        context.insert(third)
        saveAndRefresh()
    }

    private func resolve(
        _ item: QueueItem,
        preserveAvailabilityOnTransientFailure: Bool = false
    ) async {
        let itemID = item.id
        guard let url = item.originalURL,
              resolvingItemIDs.insert(itemID).inserted
        else {
            return
        }
        let wasAwaitingResolution = item.status == .resolving
        isResolving = true
        defer {
            resolvingItemIDs.remove(itemID)
            isResolving = !resolvingItemIDs.isEmpty
        }

        do {
            let resolved = try await providers.resolve(url)
            guard let liveItem = self.item(id: itemID) else { return }
            apply(resolved, to: liveItem)
            saveAndRefresh()
            if wasAwaitingResolution {
                resolutionHandler?(liveItem)
            }
        } catch {
            guard let liveItem = self.item(id: itemID) else { return }
            let policyExpiration = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            let mustDeleteExpiredYouTubeMetadata =
                liveItem.source == .youtube
                && liveItem.metadataFetchedAt.map { $0 <= policyExpiration } == true
            let isTerminalProviderFailure: Bool = {
                guard let providerError = error as? ProviderResolutionError else {
                    return false
                }
                switch providerError {
                case .itemUnavailable,
                     .youtubeVideoNotEmbeddable,
                     .invalidYouTubeVideoURL,
                     .invalidSocialVideoURL:
                    return true
                default:
                    return false
                }
            }()

            if mustDeleteExpiredYouTubeMetadata {
                purgeExpiredYouTubeMetadata(liveItem)
            } else if !preserveAvailabilityOnTransientFailure
                        || isTerminalProviderFailure
            {
                liveItem.status = .unavailable
                liveItem.unavailableReason = error.localizedDescription
                liveItem.updatedAt = Date()
                saveAndRefresh()
            } else if liveItem.status == .resolving {
                // Only this attempt failed, so a ready item whose link was
                // being refreshed stays ready, with its old link, and can
                // be tried again.
                liveItem.status = .ready
                liveItem.updatedAt = Date()
                saveAndRefresh()
            }
            lastErrorMessage = "Couldn’t resolve \(url.host() ?? "this link"): \(error.localizedDescription)"
            if wasAwaitingResolution {
                resolutionHandler?(liveItem)
            }
        }
    }

    private func apply(_ resolved: ProviderResolvedItem, to item: QueueItem) {
        if resolved.source == .youtube {
            // YouTube API metadata must be refreshed rather than retained in
            // the shared URL cache past the associated metadata timestamp.
            evictArtworkCache(for: item)
        }
        item.originalURLString = resolved.originalURL.absoluteString
        item.canonicalURLString = resolved.canonicalURL.absoluteString
        item.title = resolved.title
        item.subtitle = resolved.creatorName ?? ""
        item.artworkURLString = resolved.artworkURL?.absoluteString
        if resolved.source == .youtube {
            item.duration = resolved.duration ?? 0
        } else if let duration = resolved.duration {
            item.duration = duration
        }
        item.source = mediaSource(for: resolved.source)
        item.status = .ready
        item.unavailableReason = nil
        item.metadataFetchedAt = Date()
        item.youtubeMadeForKids = resolved.isMadeForKids
        item.youtubeEmbeddable = true

        switch resolved.playback {
        case let .remoteAudio(url):
            item.playbackURLString = url.absoluteString
            item.playbackURLExpiresAt = nil
            item.youtubeVideoID = nil
        case let .remoteVideo(url, expiresAt):
            item.playbackURLString = url.absoluteString
            item.playbackURLExpiresAt = expiresAt
            item.youtubeVideoID = nil
        case let .youtubeVideoID(videoID):
            item.youtubeVideoID = videoID
            item.playbackURLString = nil
            item.playbackURLExpiresAt = nil
        }
        item.updatedAt = Date()
    }

    private func purgeExpiredYouTubeMetadata(_ item: QueueItem) {
        evictArtworkCache(for: item)
        item.title = "YouTube video"
        item.subtitle = ""
        item.artworkURLString = nil
        item.duration = 0
        item.metadataFetchedAt = nil
        item.youtubeMadeForKids = false
        item.youtubeEmbeddable = false
        item.status = .unavailable
        item.unavailableReason = "YouTube metadata expired and could not be refreshed."
        item.updatedAt = Date()
        saveAndRefresh()
    }

    private func evictArtworkCache(for item: QueueItem) {
        guard item.source == .youtube, let artworkURL = item.artworkURL else { return }
        URLCache.shared.removeCachedResponse(for: URLRequest(url: artworkURL))
    }

    private func mediaSource(for providerSource: ProviderSource) -> MediaSource {
        switch providerSource {
        case .podcast:
            .podcast
        case .socialVideo:
            .socialVideo
        case .youtube:
            .youtube
        }
    }

    private func queueItem(_ item: QueueItem, matches url: URL) -> Bool {
        if item.originalURLString == url.absoluteString
            || item.canonicalURLString == url.absoluteString
        {
            return true
        }
        guard let candidate = SocialVideoURLParser.parse(url),
              let existingURL = item.originalURL,
              let existing = SocialVideoURLParser.parse(existingURL)
        else {
            return false
        }
        return candidate.platform == existing.platform
            && candidate.mediaID == existing.mediaID
    }

    private func nextRank() -> Double {
        (items.last?.sortRank ?? 0) + 1_000
    }

    private func applyRanks(to reordered: [QueueItem]) {
        for (index, item) in reordered.enumerated() {
            item.sortRank = Double(index + 1) * 1_000
            item.updatedAt = Date()
        }
        saveAndRefresh()
    }

    @discardableResult
    private func saveAndRefresh() -> Bool {
        do {
            try context.save()
            refresh()
            return true
        } catch {
            let message = "Couldn’t save the queue: \(error.localizedDescription)"
            context.rollback()
            refresh()
            lastErrorMessage = message
            return false
        }
    }
}
