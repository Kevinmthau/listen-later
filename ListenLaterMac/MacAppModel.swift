import AppKit
import CoreData
import Foundation
import Observation
import SwiftData

enum MacSheet: String, Identifiable {
    case addLink

    var id: String { rawValue }
}

private struct MacDeletionUndo {
    let snapshot: QueueItemSnapshot
    let trashedMedia: TrashedLocalMedia?
    let wasLocal: Bool
}

@MainActor
@Observable
final class MacAppModel {
    let sharedQueue: QueueStore
    let localQueue: LocalQueueStore
    let playback: MacPlaybackCoordinator
    let isCloudBacked: Bool
    let persistenceNotice: String?

    /// How often the shared queue is re-read in case a persistent-store
    /// change notification is missed while the app remains active.
    static let safetyNetRefreshInterval: Duration = .seconds(30)

    private(set) var localAvailability: [UUID: Bool] = [:]
    private(set) var isImporting = false
    var selectedItemID: UUID?
    var presentedSheet: MacSheet?
    var isShowingImporter = false
    var userMessage: String?

    @ObservationIgnored private let localMediaLibrary: LocalMediaLibrary
    @ObservationIgnored private let sharedContainer: ModelContainer
    @ObservationIgnored private let localContainer: ModelContainer
    @ObservationIgnored private var deletionUndo: MacDeletionUndo?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var queueObservationTask: Task<Void, Never>?
    @ObservationIgnored private var storeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var storeChangeRefreshTask: Task<Void, Never>?

    var items: [QueueItem] {
        (sharedQueue.items + localQueue.items).sorted(by: Self.queueOrder)
    }

    var selectedItem: QueueItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    var canUndoDeletion: Bool { deletionUndo != nil }

    init(
        sharedPersistence: PersistenceController.Result,
        localContainer: ModelContainer,
        localMediaLibrary: LocalMediaLibrary
    ) {
        let providers = ProviderRegistry(
            youtubeAPIKey: "",
            videoGrabberEndpoint: AppConfiguration.videoGrabberEndpoint,
            videoGrabberAPIToken: AppConfiguration.videoGrabberAPIToken
        )
        let sharedQueue = QueueStore(
            context: sharedPersistence.container.mainContext,
            providers: providers
        )
        let localQueue = LocalQueueStore(context: localContainer.mainContext)
        self.sharedQueue = sharedQueue
        self.localQueue = localQueue
        self.localMediaLibrary = localMediaLibrary
        sharedContainer = sharedPersistence.container
        self.localContainer = localContainer
        self.isCloudBacked = sharedPersistence.isCloudBacked
        self.persistenceNotice = sharedPersistence.fallbackReason
        playback = MacPlaybackCoordinator(
            sharedQueue: sharedQueue,
            localQueue: localQueue,
            localMediaLibrary: localMediaLibrary
        )
    }

    func start() async {
        guard !hasStarted, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            try await localMediaLibrary.prepare()
            try await localMediaLibrary.cleanStalePartials()
            try await localMediaLibrary.cleanTrash()
        } catch {
            userMessage = "Local media maintenance failed: \(error.localizedDescription)"
        }
        sharedQueue.refresh()
        let localQueueLoaded = localQueue.refresh()
        await sharedQueue.resumePendingResolutions()
        await sharedQueue.refreshExpiredYouTubeMetadata()
        if localQueueLoaded {
            await reconcileLocalMedia()
        } else {
            await handleLocalQueueRefreshFailure()
        }
        reconcileQueuePresentation()
        hasStarted = true
        beginQueueObservation()
    }

    func refresh() async {
        // SwiftUI can report the initial active scene while `.task` is still
        // awaiting local maintenance. Let that first start own the contexts;
        // later activations perform the normal CloudKit/local refresh.
        guard hasStarted else { return }
        beginQueueObservation()
        sharedQueue.refresh()
        if localQueue.refresh() {
            await reconcileLocalMedia()
        } else {
            await handleLocalQueueRefreshFailure()
        }
        reconcileQueuePresentation()
    }

    func sceneWillResignActive() {
        queueObservationTask?.cancel()
        queueObservationTask = nil
        storeChangeRefreshTask?.cancel()
        storeChangeRefreshTask = nil
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
            self.storeChangeObserver = nil
        }
    }

    func addLink(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            userMessage = "Enter a public https:// link."
            return false
        }
        guard let item = await sharedQueue.add(url: url) else {
            userMessage = sharedQueue.userMessage?.text ?? "That link could not be added."
            return false
        }
        selectedItemID = item.id
        userMessage = sharedQueue.userMessage?.text
        return true
    }

    func importVideos(from urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        var importedCount = 0
        var failures: [String] = []

        for url in urls {
            do {
                let imported = try await localMediaLibrary.importVideo(from: url)
                let rank = nextRank()
                guard let item = localQueue.insertLocalVideo(
                    mediaID: imported.mediaID,
                    filename: imported.filename,
                    posterFilename: imported.posterFilename,
                    title: imported.title,
                    duration: imported.duration,
                    pixelWidth: imported.pixelWidth,
                    pixelHeight: imported.pixelHeight,
                    sortRank: rank
                ) else {
                    _ = try? await localMediaLibrary.moveToTrash(mediaID: imported.mediaID)
                    failures.append("\(url.lastPathComponent): metadata could not be saved")
                    continue
                }
                localAvailability[item.id] = true
                selectedItemID = item.id
                importedCount += 1
            } catch is CancellationError {
                failures.append("Import cancelled")
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            userMessage = importedCount == 1
                ? "Imported 1 video."
                : "Imported \(importedCount) videos."
        } else {
            let prefix = importedCount > 0 ? "Imported \(importedCount). " : ""
            userMessage = prefix + failures.joined(separator: "\n")
        }
        isImporting = false
        // A refresh that arrives while files are being copied deliberately
        // skips reconciliation. Run it once metadata for every committed
        // import is durable so no newly imported directory can look orphaned.
        await reconcileLocalMedia()
    }

    func delete(_ item: QueueItem) async {
        let wasLocal = item.source == .localVideo
        let snapshot = wasLocal ? localQueue.delete(item) : sharedQueue.delete(item)
        guard let snapshot else { return }

        var trashed: TrashedLocalMedia?
        if wasLocal, let mediaID = snapshot.localMediaIDString.flatMap(UUID.init(uuidString:)) {
            do {
                trashed = try await localMediaLibrary.moveToTrash(mediaID: mediaID)
            } catch {
                userMessage = "The queue item was removed, but its local file could not be moved to Trash: \(error.localizedDescription)"
            }
        }
        deletionUndo = MacDeletionUndo(
            snapshot: snapshot,
            trashedMedia: trashed,
            wasLocal: wasLocal
        )
        localAvailability[item.id] = nil
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
        playback.itemWasDeleted(item.id)
    }

    func undoDeletion() async {
        guard let deletionUndo else { return }
        self.deletionUndo = nil
        if let trashed = deletionUndo.trashedMedia {
            do {
                _ = try await localMediaLibrary.restoreFromTrash(trashed)
            } catch {
                userMessage = "The queue item was restored, but its local file could not be restored: \(error.localizedDescription)"
            }
        }
        if deletionUndo.wasLocal {
            localQueue.restore([deletionUndo.snapshot])
        } else {
            sharedQueue.restore([deletionUndo.snapshot])
        }
        selectedItemID = deletionUndo.snapshot.id
        await refreshLocalAvailability()
    }

    func setPlayed(_ item: QueueItem, played: Bool) {
        if item.source == .localVideo {
            if played {
                localQueue.markPlayed(item)
            } else {
                localQueue.markUnplayed(item)
            }
        } else {
            if played {
                sharedQueue.markPlayed(item)
            } else {
                sharedQueue.markUnplayed(item)
            }
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
        let insertion = min(max(0, destination - removedBeforeDestination), reordered.count)
        reordered.insert(contentsOf: moving, at: insertion)
        persistOrder(reordered, moved: moving)
    }

    func move(_ item: QueueItem, offset: Int) {
        var reordered = items
        guard let index = reordered.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = min(max(0, index + offset), reordered.count - 1)
        guard destination != index else { return }
        reordered.remove(at: index)
        reordered.insert(item, at: destination)
        persistOrder(reordered, moved: [item])
    }

    func openOriginal(_ item: QueueItem) {
        guard item.source != .localVideo,
              item.source != .unknown,
              let url = item.canonicalURL ?? item.originalURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func localPosterURL(for item: QueueItem) async -> URL? {
        guard let mediaID = item.localMediaID else { return nil }
        return await localMediaLibrary.posterURL(
            mediaID: mediaID,
            filename: item.localPosterFilename
        )
    }

    private func reconcileLocalMedia() async {
        guard !isImporting else { return }
        let referenced = Set(localQueue.items.compactMap(\.localMediaID))
        do {
            try await localMediaLibrary.reconcile(referencedMediaIDs: referenced)
        } catch {
            userMessage = "Local media reconciliation failed: \(error.localizedDescription)"
        }
        await refreshLocalAvailability()
    }

    private func handleLocalQueueRefreshFailure() async {
        userMessage = "Local video metadata could not be loaded. MushRadio left all imported files untouched."
        await refreshLocalAvailability()
    }

    private func reconcileQueuePresentation() {
        playback.reconcileQueueState()
        if let selectedItemID,
           items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = items.first?.id
    }

    /// Observe CloudKit imports while the Mac app is active, with a low-rate
    /// refresh as a fallback for missed persistent-store notifications.
    private func beginQueueObservation() {
        if storeChangeObserver == nil {
            storeChangeObserver = NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.storeDidChange()
                }
            }
        }

        guard queueObservationTask == nil else { return }
        queueObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.safetyNetRefreshInterval)
                } catch {
                    return
                }
                guard let self else { return }
                self.sharedQueue.refresh()
                self.reconcileQueuePresentation()
            }
        }
    }

    /// CloudKit imports can post several transaction notifications together,
    /// so coalesce each burst into one queue refresh.
    private func storeDidChange() {
        guard storeChangeRefreshTask == nil else { return }
        storeChangeRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            self.storeChangeRefreshTask = nil
            self.sharedQueue.refresh()
            self.reconcileQueuePresentation()
        }
    }

    private func refreshLocalAvailability() async {
        var availability: [UUID: Bool] = [:]
        for item in localQueue.items {
            guard let mediaID = item.localMediaID else {
                availability[item.id] = false
                continue
            }
            availability[item.id] = await localMediaLibrary.contains(
                mediaID: mediaID,
                filename: item.localFilename
            )
        }
        localAvailability = availability
    }

    private func persistOrder(_ reordered: [QueueItem], moved: [QueueItem]) {
        let ranks: [UUID: Double]
        if let sparseRanks = QueueStore.sparseSortRanks(
            for: reordered,
            preferringToMove: Set(moved.map(\.id))
        ) {
            ranks = sparseRanks
        } else {
            ranks = Dictionary(uniqueKeysWithValues: reordered.enumerated().map {
                ($0.element.id, Double($0.offset + 1) * QueueStore.rankSpacing)
            })
        }
        guard !ranks.isEmpty else { return }
        sharedQueue.updateSortRanks(ranks)
        localQueue.updateSortRanks(ranks)
    }

    private func nextRank() -> Double {
        (items.map(\.sortRank).max() ?? 0) + 1
    }

    private static func queueOrder(_ lhs: QueueItem, _ rhs: QueueItem) -> Bool {
        if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
