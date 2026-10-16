import Foundation
import Observation
import SwiftData

/// Persistent metadata for a movie copied into this Mac's app-owned storage.
/// It intentionally has a different SwiftData model type from `QueueItem` so
/// the live app never registers one model class with two independent stores.
@Model
final class LocalQueueRecord {
    var id: UUID = UUID()
    var mediaID: UUID = UUID()
    var filename: String = ""
    var posterFilename: String?
    var title: String = "Local video"
    var duration: TimeInterval = 0
    var pixelWidth: Double = 0
    var pixelHeight: Double = 0
    var sortRank: Double = 0
    var playbackPosition: TimeInterval = 0
    var playbackRate: Double = 1
    var isPlayed = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var progressUpdatedAt: Date = Date.distantPast
    var lastPlayedAt: Date?

    init(
        id: UUID = UUID(),
        mediaID: UUID,
        filename: String,
        posterFilename: String?,
        title: String,
        duration: TimeInterval,
        pixelWidth: Double,
        pixelHeight: Double,
        sortRank: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.filename = filename
        self.posterFilename = posterFilename
        self.title = title
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sortRank = sortRank
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}

/// A Mac-only metadata store. Its public items are unattached `QueueItem`
/// projections so the existing queue UI and playback semantics stay shared,
/// while only `LocalQueueRecord` instances enter this local SwiftData context.
@MainActor
@Observable
final class LocalQueueStore {
    private(set) var items: [QueueItem] = []

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var recordsByID: [UUID: LocalQueueRecord] = [:]
    @ObservationIgnored private var lastProgressSaveAt: [UUID: Date] = [:]

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    static func makeContainer(
        inMemory: Bool = false,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([LocalQueueRecord.self])
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(
                "ListenLaterMacLocalQueue",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "ListenLaterMacLocalQueue",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Reloads the local metadata without discarding the last known-good
    /// snapshot when SwiftData cannot be read. Callers use the result to
    /// avoid treating a transient fetch failure as an empty authoritative
    /// library during file reconciliation.
    @discardableResult
    func refresh() -> Bool {
        do {
            let records = try context.fetch(FetchDescriptor<LocalQueueRecord>())
            recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            items = records.map(Self.makeItem).sorted(by: Self.queueOrder)
            return true
        } catch {
            return false
        }
    }

    func item(id: UUID?) -> QueueItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    @discardableResult
    func insertLocalVideo(
        mediaID: UUID,
        filename: String,
        posterFilename: String?,
        title: String,
        duration: TimeInterval,
        pixelWidth: Double,
        pixelHeight: Double,
        sortRank: Double
    ) -> QueueItem? {
        let record = LocalQueueRecord(
            mediaID: mediaID,
            filename: filename,
            posterFilename: posterFilename,
            title: title,
            duration: duration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            sortRank: sortRank
        )
        context.insert(record)
        guard save() else { return nil }
        refresh()
        return item(id: record.id)
    }

    func delete(_ item: QueueItem) -> QueueItemSnapshot? {
        guard let record = recordsByID[item.id] else { return nil }
        let snapshot = item.snapshot()
        context.delete(record)
        guard save() else { return nil }
        refresh()
        return snapshot
    }

    func restore(_ snapshots: [QueueItemSnapshot]) {
        for snapshot in snapshots where recordsByID[snapshot.id] == nil {
            guard
                snapshot.sourceRawValue == MediaSource.localVideo.rawValue,
                let mediaIDString = snapshot.localMediaIDString,
                let mediaID = UUID(uuidString: mediaIDString),
                let filename = snapshot.localFilename
            else { continue }
            let record = LocalQueueRecord(
                id: snapshot.id,
                mediaID: mediaID,
                filename: filename,
                posterFilename: snapshot.localPosterFilename,
                title: snapshot.title,
                duration: snapshot.duration,
                pixelWidth: snapshot.localPixelWidth,
                pixelHeight: snapshot.localPixelHeight,
                sortRank: snapshot.sortRank,
                createdAt: snapshot.createdAt
            )
            record.playbackPosition = snapshot.playbackPosition
            record.playbackRate = snapshot.playbackRate
            record.isPlayed = snapshot.isPlayed
            record.updatedAt = snapshot.updatedAt
            record.progressUpdatedAt = snapshot.progressUpdatedAt
            record.lastPlayedAt = snapshot.lastPlayedAt
            context.insert(record)
        }
        _ = save()
        refresh()
    }

    func markPlayed(_ item: QueueItem) {
        guard let record = recordsByID[item.id] else { return }
        record.isPlayed = true
        record.playbackPosition = max(item.duration, item.playbackPosition)
        record.lastPlayedAt = Date()
        record.updatedAt = Date()
        _ = save()
        apply(record, to: item)
    }

    func markUnplayed(_ item: QueueItem) {
        guard let record = recordsByID[item.id] else { return }
        record.isPlayed = false
        record.playbackPosition = 0
        record.updatedAt = Date()
        _ = save()
        apply(record, to: item)
    }

    func recordPlaybackStarted(for item: QueueItem) {
        guard let record = recordsByID[item.id] else { return }
        record.lastPlayedAt = Date()
        record.updatedAt = Date()
        _ = save()
        apply(record, to: item)
    }

    func saveProgress(
        for item: QueueItem,
        position: TimeInterval,
        duration: TimeInterval,
        rate: Double,
        force: Bool
    ) {
        guard let record = recordsByID[item.id] else { return }
        let now = Date()
        if !force,
           let lastSave = lastProgressSaveAt[item.id],
           now.timeIntervalSince(lastSave) < 5 {
            return
        }
        let safeDuration = duration.isFinite ? max(0, duration) : record.duration
        let upperBound = safeDuration > 0 ? safeDuration : max(0, position)
        record.duration = safeDuration
        record.playbackPosition = min(max(0, position), upperBound)
        record.playbackRate = rate > 0 && rate.isFinite ? rate : 1
        record.progressUpdatedAt = now
        record.updatedAt = now
        guard save() else { return }
        lastProgressSaveAt[item.id] = now
        apply(record, to: item)
    }

    func updateSortRanks(_ ranks: [UUID: Double]) {
        var changed = false
        for (id, rank) in ranks {
            guard let record = recordsByID[id], record.sortRank != rank else { continue }
            record.sortRank = rank
            record.updatedAt = Date()
            changed = true
        }
        guard changed, save() else { return }
        for item in items {
            if let rank = ranks[item.id] { item.sortRank = rank }
        }
        items.sort(by: Self.queueOrder)
    }

    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private static func makeItem(_ record: LocalQueueRecord) -> QueueItem {
        let item = QueueItem(
            id: record.id,
            originalURL: URL(string: "mushradio-local://media/\(record.mediaID.uuidString)")!,
            title: record.title,
            source: .localVideo,
            status: .ready,
            sortRank: record.sortRank,
            createdAt: record.createdAt
        )
        apply(record, to: item)
        return item
    }

    private static func apply(_ record: LocalQueueRecord, to item: QueueItem) {
        item.localMediaID = record.mediaID
        item.localFilename = record.filename
        item.localPosterFilename = record.posterFilename
        item.localPixelWidth = record.pixelWidth
        item.localPixelHeight = record.pixelHeight
        item.title = record.title
        item.duration = record.duration
        item.sortRank = record.sortRank
        item.playbackPosition = record.playbackPosition
        item.playbackRate = record.playbackRate
        item.isPlayed = record.isPlayed
        item.updatedAt = record.updatedAt
        item.progressUpdatedAt = record.progressUpdatedAt
        item.lastPlayedAt = record.lastPlayedAt
    }

    private func apply(_ record: LocalQueueRecord, to item: QueueItem) {
        Self.apply(record, to: item)
    }

    private static func queueOrder(_ lhs: QueueItem, _ rhs: QueueItem) -> Bool {
        if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
