import Foundation
import XCTest

@MainActor
final class MacAppModelReconciliationTests: XCTestCase {
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
