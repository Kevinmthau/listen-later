import CoreData
import Foundation
import SwiftData
import XCTest

@MainActor
final class MacAppModelReconciliationTests: XCTestCase {
    func testAddedLinkIsSavedInSharedQueueAndVisibleToAnotherContext() async throws {
        let harness = try makeSyncHarness()
        defer { harness.model.sceneWillResignActive() }
        let url = URL(string: "https://example.com/episode.mp3")!

        let added = await harness.model.addLink(url.absoluteString)

        XCTAssertTrue(added)
        let reader = ModelContext(harness.persistence.container)
        let rows = try reader.fetch(FetchDescriptor<QueueItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.originalURL, url)
        XCTAssertEqual(rows.first?.status, .ready)
        XCTAssertEqual(harness.model.selectedItemID, rows.first?.id)
        XCTAssertTrue(harness.model.localQueue.items.isEmpty)
    }

    func testRemoteStoreNotificationImportsAndResolvesLinkWhileActive() async throws {
        let harness = try makeSyncHarness()
        await harness.model.start()
        defer { harness.model.sceneWillResignActive() }
        let writer = ModelContext(harness.persistence.container)
        let incoming = QueueItem(
            originalURL: URL(string: "https://example.com/incoming.mp3")!,
            source: .podcast,
            sortRank: 1_000
        )
        writer.insert(incoming)
        try writer.save()
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)

        let deadline = ContinuousClock.now + .seconds(5)
        while harness.model.sharedQueue.item(id: incoming.id)?.status != .ready,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let imported = try XCTUnwrap(harness.model.sharedQueue.item(id: incoming.id))
        XCTAssertEqual(imported.status, .ready)
        XCTAssertEqual(imported.originalURL, incoming.originalURL)
        XCTAssertEqual(harness.model.selectedItemID, incoming.id)
    }

    func testActivationImportsLinkReceivedWhileInactive() async throws {
        let harness = try makeSyncHarness()
        await harness.model.start()
        harness.model.sceneWillResignActive()
        defer { harness.model.sceneWillResignActive() }
        let writer = ModelContext(harness.persistence.container)
        let incoming = QueueItem(
            originalURL: URL(string: "https://example.com/background.mp3")!,
            source: .podcast,
            sortRank: 1_000
        )
        writer.insert(incoming)
        try writer.save()

        await harness.model.refresh()

        XCTAssertEqual(harness.model.sharedQueue.item(id: incoming.id)?.status, .ready)
    }

    private func makeSyncHarness() throws -> (
        model: MacAppModel, persistence: PersistenceController.Result
    ) {
        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "MacSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = MacAppModel(
            sharedPersistence: persistence,
            localContainer: try LocalQueueStore.makeContainer(inMemory: true),
            localMediaLibrary: LocalMediaLibrary(root: root),
            // Direct audio resolution is deterministic; omit network endpoint checks.
            providers: ProviderRegistry(providers: [PodcastProviderAdapter()])
        )
        return (model, persistence)
    }

    func testRefreshDoesNotReconcileWhileImportIsInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "MacAppModelTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "source.mov")
        try Data("movie".utf8).write(to: source)
        let ownedRoot = root.appending(path: "Owned", directoryHint: .isDirectory)
        let inspectionGate = ImportInspectionGate()
        let library = LocalMediaLibrary(root: ownedRoot) { _ in
            await inspectionGate.waitUntilReleased()
            return LocalMediaInspection(
                title: "Imported",
                duration: 30,
                pixelWidth: 640,
                pixelHeight: 480,
                posterJPEGData: nil
            )
        }
        let sharedPersistence = try PersistenceController.makeContainer(inMemory: true)
        let localContainer = try LocalQueueStore.makeContainer(inMemory: true)
        let model = MacAppModel(
            sharedPersistence: sharedPersistence,
            localContainer: localContainer,
            localMediaLibrary: library
        )
        await model.start()
        defer { model.sceneWillResignActive() }

        let orphanID = UUID()
        let orphanDirectory = ownedRoot
            .appending(path: "Media", directoryHint: .isDirectory)
            .appending(path: orphanID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: true
        )
        try Data("orphan".utf8).write(
            to: orphanDirectory.appending(path: "orphan.mov")
        )

        let importTask = Task { await model.importVideos(from: [source]) }
        await inspectionGate.waitUntilStarted()
        await model.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanDirectory.path))

        await inspectionGate.release()
        await importTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
        let imported = try XCTUnwrap(model.localQueue.items.first)
        let mediaID = try XCTUnwrap(imported.localMediaID)
        let isAvailable = await library.contains(
            mediaID: mediaID,
            filename: imported.localFilename
        )
        XCTAssertTrue(isAvailable)
        XCTAssertTrue(try sharedPersistence.container.mainContext.fetch(
            FetchDescriptor<QueueItem>()
        ).isEmpty)
    }
}

private actor ImportInspectionGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
