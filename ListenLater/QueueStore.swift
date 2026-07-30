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
            $0.originalURLString == url.absoluteString || $0.canonicalURLString == url.absoluteString
        }) {
            let wasPlayed = existing.isPlayed
            existing.isPlayed = false
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
        let source = provider?.source == .youtube ? MediaSource.youtube : .podcast
        let item = QueueItem(
            originalURL: url,
            title: source == .youtube ? "YouTube video" : "Podcast episode",
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
        let stale = items.filter {
            $0.source == .youtube
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

    func moveToPlayNext(_ item: QueueItem, after currentID: UUID?) {
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

    func delete(_ item: QueueItem) {
        evictArtworkCache(for: item)
        context.delete(item)
        saveAndRefresh()
        normalizeRanks()
    }

    func markPlayed(_ item: QueueItem) {
        item.isPlayed = true
        if item.source == .podcast, item.duration > 0 {
            item.playbackPosition = item.duration
        }
        item.updatedAt = Date()
        item.progressUpdatedAt = Date()
        saveAndRefresh()
    }

    func markUnplayed(_ item: QueueItem) {
        item.isPlayed = false
        item.playbackPosition = 0
        item.updatedAt = Date()
        item.progressUpdatedAt = Date()
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
        if item.source == .podcast {
            let completionThreshold = item.duration > 10
                ? item.duration - 2
                : item.duration * 0.95
            item.isPlayed = item.duration > 0
                && item.playbackPosition > 0
                && item.playbackPosition >= completionThreshold
        }
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

    func firstUnplayed() -> QueueItem? {
        items.first { !$0.isPlayed && $0.status != .unavailable }
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
            !$0.isPlayed && $0.status != .unavailable
        }
    }

    func item(id: UUID?) -> QueueItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func appendResolvedForTesting(_ resolved: ProviderResolvedItem) -> QueueItem {
        let source: MediaSource = resolved.source == .youtube ? .youtube : .podcast
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
                     .invalidYouTubeVideoURL:
                    return true
                default:
                    return false
                }
            }()

            if mustDeleteExpiredYouTubeMetadata {
                evictArtworkCache(for: liveItem)
                liveItem.title = "YouTube video"
                liveItem.subtitle = ""
                liveItem.artworkURLString = nil
                liveItem.duration = 0
                liveItem.metadataFetchedAt = nil
                liveItem.youtubeMadeForKids = false
                liveItem.youtubeEmbeddable = false
                liveItem.status = .unavailable
                liveItem.unavailableReason = "YouTube metadata expired and could not be refreshed."
                liveItem.updatedAt = Date()
                saveAndRefresh()
            } else if !preserveAvailabilityOnTransientFailure
                        || isTerminalProviderFailure
            {
                liveItem.status = .unavailable
                liveItem.unavailableReason = error.localizedDescription
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
        item.source = resolved.source == .youtube ? .youtube : .podcast
        item.status = .ready
        item.unavailableReason = nil
        item.metadataFetchedAt = Date()
        item.youtubeMadeForKids = resolved.isMadeForKids
        item.youtubeEmbeddable = true

        switch resolved.playback {
        case let .remoteAudio(url):
            item.playbackURLString = url.absoluteString
            item.youtubeVideoID = nil
        case let .youtubeVideoID(videoID):
            item.youtubeVideoID = videoID
            item.playbackURLString = nil
        }
        item.updatedAt = Date()
    }

    private func evictArtworkCache(for item: QueueItem) {
        guard item.source == .youtube, let artworkURL = item.artworkURL else { return }
        URLCache.shared.removeCachedResponse(for: URLRequest(url: artworkURL))
    }

    private func nextRank() -> Double {
        (items.last?.sortRank ?? 0) + 1_000
    }

    private func normalizeRanks() {
        applyRanks(to: items)
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
