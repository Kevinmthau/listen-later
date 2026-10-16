import Foundation
import SwiftData
import XCTest

@MainActor
final class LocalQueueCompatibilityTests: XCTestCase {
    func testUnknownSourceDoesNotBecomePodcastAndSnapshotRestoresLocalMetadata() throws {
        let item = QueueItem(
            originalURL: URL(string: "mushradio-local://media/test")!,
            title: "Movie",
            source: .localVideo,
            status: .ready,
            sortRank: 1
        )
        let mediaID = UUID()
        item.localMediaID = mediaID
        item.localFilename = "movie.mov"
        item.localPosterFilename = "poster.jpg"
        item.localPixelWidth = 1_920
        item.localPixelHeight = 1_080

        let restored = try XCTUnwrap(item.snapshot().makeItem())
        XCTAssertEqual(restored.source, .localVideo)
        XCTAssertEqual(restored.localMediaID, mediaID)
        XCTAssertEqual(restored.localFilename, "movie.mov")
        XCTAssertEqual(restored.localPosterFilename, "poster.jpg")
        XCTAssertEqual(restored.localPixelWidth, 1_920)
        XCTAssertNil(restored.videoShareURL)

        restored.sourceRawValue = "future-source"
        XCTAssertEqual(restored.source, .unknown)
        XCTAssertNotEqual(restored.source, .podcast)

        let futureRestored = try XCTUnwrap(restored.snapshot().makeItem())
        XCTAssertEqual(futureRestored.sourceRawValue, "future-source")
        XCTAssertEqual(futureRestored.source, .unknown)
    }

    func testSparseMergedQueueRanksOnlyRewriteTheMovedLocalItem() throws {
        let firstShared = QueueItem(
            originalURL: URL(string: "https://example.com/first")!,
            title: "First",
            source: .podcast,
            status: .ready,
            sortRank: 1_000
        )
        let secondShared = QueueItem(
            originalURL: URL(string: "https://example.com/second")!,
            title: "Second",
            source: .podcast,
            status: .ready,
            sortRank: 2_000
        )
        let movedLocal = QueueItem(
            originalURL: URL(string: "mushradio-local://media/test")!,
            title: "Local",
            source: .localVideo,
            status: .ready,
            sortRank: 3_000
        )

        let ranks = try XCTUnwrap(QueueStore.sparseSortRanks(
            for: [firstShared, movedLocal, secondShared],
            preferringToMove: [movedLocal.id]
        ))

        XCTAssertEqual(Set(ranks.keys), [movedLocal.id])
        XCTAssertEqual(ranks[movedLocal.id], 1_500)
    }

    func testLocalContainerDoesNotUseCloudKit() throws {
        let container = try LocalQueueStore.makeContainer(inMemory: true)
        let queue = LocalQueueStore(context: container.mainContext)
        let mediaID = UUID()
        let item = try XCTUnwrap(queue.insertLocalVideo(
            mediaID: mediaID,
            filename: "movie.mov",
            posterFilename: nil,
            title: "Movie",
            duration: 12,
            pixelWidth: 640,
            pixelHeight: 480,
            sortRank: 1
        ))
        XCTAssertEqual(item.source, .localVideo)
        XCTAssertEqual(item.originalURL?.scheme, "mushradio-local")
        XCTAssertNil(item.videoShareURL)
    }

    func testLocalMetadataSurvivesContainerRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "LocalQueueRelaunch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalQueue.store")
        let mediaID = UUID()
        let itemID: UUID

        do {
            let container = try LocalQueueStore.makeContainer(storeURL: storeURL)
            let queue = LocalQueueStore(context: container.mainContext)
            let item = try XCTUnwrap(queue.insertLocalVideo(
                mediaID: mediaID,
                filename: "movie.mov",
                posterFilename: "poster.jpg",
                title: "Persistent Movie",
                duration: 90,
                pixelWidth: 1_920,
                pixelHeight: 1_080,
                sortRank: 2
            ))
            queue.saveProgress(
                for: item,
                position: 31,
                duration: 90,
                rate: 1.25,
                force: true
            )
            itemID = item.id
        }

        let relaunchedContainer = try LocalQueueStore.makeContainer(storeURL: storeURL)
        let relaunchedQueue = LocalQueueStore(context: relaunchedContainer.mainContext)
        let restored = try XCTUnwrap(relaunchedQueue.item(id: itemID))
        XCTAssertEqual(restored.localMediaID, mediaID)
        XCTAssertEqual(restored.title, "Persistent Movie")
        XCTAssertEqual(restored.playbackPosition, 31)
        XCTAssertEqual(restored.playbackRate, 1.25)
    }
}
