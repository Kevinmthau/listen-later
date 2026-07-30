import Foundation
import SwiftData
import XCTest
@testable import ListenLater

final class SharedQueueInboxTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ListenLaterInboxTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path)
        {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testPendingReturnsChronologicalSharesAndRequiresAcknowledgement() throws {
        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let later = PendingShare(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            url: URL(string: "https://example.com/later")!,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let earlier = PendingShare(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            url: URL(string: "https://example.com/earlier")!,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        try inbox.enqueue(later)
        try inbox.enqueue(earlier)

        let receipts = try inbox.pending()
        XCTAssertEqual(receipts.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(
            try inbox.pending().map(\.id),
            [earlier.id, later.id],
            "Reading pending shares must not consume them."
        )

        try inbox.acknowledge(receipts[0])
        try inbox.acknowledge(receipts[0])
        XCTAssertEqual(try inbox.pending().map(\.id), [later.id])

        try inbox.acknowledge(receipts[1])
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testPendingQuarantinesMalformedFilesAndReportsThemOnce() throws {
        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let malformedURL = temporaryDirectory
            .appendingPathComponent("malformed.json")
        try Data("{not-json".utf8).write(to: malformedURL)

        XCTAssertThrowsError(try inbox.pending()) { error in
            guard case SharedQueueInbox.InboxError.quarantinedMalformedFiles(1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedURL.path))
        XCTAssertTrue(try inbox.pending().isEmpty)
        let quarantine = temporaryDirectory.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testPendingBatchPreservesValidReceiptsWhenAnotherFileIsMalformed() throws {
        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let valid = PendingShare(
            url: URL(string: "https://example.com/valid")!
        )
        try inbox.enqueue(valid)
        try Data("{not-json".utf8).write(
            to: temporaryDirectory.appendingPathComponent("damaged.json")
        )

        let batch = try inbox.pendingBatch()

        XCTAssertEqual(batch.receipts.map(\.id), [valid.id])
        XCTAssertEqual(batch.quarantinedFileCount, 1)
        try inbox.acknowledge(try XCTUnwrap(batch.receipts.first))
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testEnqueuePostsCrossProcessNotification() throws {
        let inbox = SharedQueueInbox(
            directoryURL: temporaryDirectory,
            notificationName: "com.kevinthau.ListenLater.tests.\(UUID().uuidString)"
        )
        let notification = expectation(description: "Inbox enqueue notification")
        let observation = inbox.observeEnqueues {
            notification.fulfill()
        }

        try inbox.enqueue(
            PendingShare(url: URL(string: "https://example.com/notified")!)
        )

        wait(for: [notification], timeout: 1)
        withExtendedLifetime(observation) {}
    }
}

@MainActor
final class QueueStoreShareImportTests: XCTestCase {
    func testInterruptedPendingReadCanStillBeImportedAndAcknowledged() async throws {
        let temporaryDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let share = PendingShare(
            url: URL(string: "https://podcasts.example/episodes/durable")!
        )
        try inbox.enqueue(share)

        XCTAssertEqual(try inbox.pending().map(\.id), [share.id])

        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let store = QueueStore(
            context: persistence.container.mainContext,
            providers: ProviderRegistry(
                providers: [
                    SharedInboxStubProvider(
                        inbox: inbox,
                        expectedAcknowledgedShareID: share.id
                    )
                ]
            ),
            inbox: inbox
        )

        await store.importPendingShares()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.originalURL, share.url)
        XCTAssertEqual(store.items.first?.status, .ready)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testPreviouslyStagedReceiptIsAcknowledgedWithoutRestaging() async throws {
        let temporaryDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let share = PendingShare(
            url: URL(string: "https://podcasts.example/episodes/already-staged")!
        )
        try inbox.enqueue(share)

        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let item = QueueItem(
            originalURL: share.url,
            title: "Already resolved",
            source: .podcast,
            status: .ready,
            sortRank: 1_000
        )
        item.pendingShareReceiptIDString = share.id.uuidString
        persistence.container.mainContext.insert(item)
        try persistence.container.mainContext.save()
        let itemID = item.id

        let store = QueueStore(
            context: ModelContext(persistence.container),
            providers: ProviderRegistry(providers: []),
            inbox: inbox
        )

        await store.importPendingShares()

        let restored = try XCTUnwrap(store.item(id: itemID))
        XCTAssertEqual(store.items.map(\.id), [itemID])
        XCTAssertEqual(restored.title, "Already resolved")
        XCTAssertEqual(restored.status, .ready)
        XCTAssertEqual(restored.sortRank, 1_000)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testPreviouslyStagedResolvingReceiptResumesAfterAcknowledgement() async throws {
        let temporaryDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let share = PendingShare(
            url: URL(string: "https://podcasts.example/episodes/resume-staged")!
        )
        try inbox.enqueue(share)

        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let item = QueueItem(
            originalURL: share.url,
            title: "Podcast episode",
            source: .podcast,
            status: .resolving,
            sortRank: 1_000
        )
        item.pendingShareReceiptIDString = share.id.uuidString
        persistence.container.mainContext.insert(item)
        try persistence.container.mainContext.save()
        let itemID = item.id

        let store = QueueStore(
            context: ModelContext(persistence.container),
            providers: ProviderRegistry(
                providers: [
                    SharedInboxStubProvider(
                        inbox: inbox,
                        expectedAcknowledgedShareID: share.id
                    )
                ]
            ),
            inbox: inbox
        )

        await store.importPendingShares()

        let restored = try XCTUnwrap(store.item(id: itemID))
        XCTAssertEqual(store.items.map(\.id), [itemID])
        XCTAssertEqual(restored.title, "Durable episode")
        XCTAssertEqual(restored.status, .ready)
        XCTAssertEqual(restored.sortRank, 1_000)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testImportDiscardsPermanentlyUnsupportedReceipt() async throws {
        let temporaryDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let share = PendingShare(url: URL(string: "ftp://example.com/episode")!)
        try inbox.enqueue(share)

        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let store = QueueStore(
            context: persistence.container.mainContext,
            providers: ProviderRegistry(providers: []),
            inbox: inbox
        )

        await store.importPendingShares()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testAllReceiptsAreStagedBeforeSlowResolutionCompletes() async throws {
        let temporaryDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inbox = SharedQueueInbox(directoryURL: temporaryDirectory)
        let first = PendingShare(
            url: URL(string: "https://podcasts.example/episodes/first")!
        )
        let second = PendingShare(
            url: URL(string: "https://podcasts.example/episodes/second")!,
            createdAt: first.createdAt.addingTimeInterval(1)
        )
        try inbox.enqueue(first)
        try inbox.enqueue(second)

        let gate = SharedInboxResolutionGate()
        let persistence = try PersistenceController.makeContainer(inMemory: true)
        let store = QueueStore(
            context: persistence.container.mainContext,
            providers: ProviderRegistry(
                providers: [
                    DelayedSharedInboxProvider(inbox: inbox, gate: gate)
                ]
            ),
            inbox: inbox
        )

        let importTask = Task { @MainActor in
            await store.importPendingShares()
        }
        await gate.waitUntilStarted()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(
            store.items.compactMap(\.originalURL?.lastPathComponent),
            ["first", "second"]
        )
        XCTAssertTrue(try inbox.pending().isEmpty)

        await gate.release()
        await importTask.value

        XCTAssertEqual(store.items.map(\.status), [.ready, .ready])
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ListenLaterQueueImportTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct SharedInboxStubProvider: MediaProvider {
    let source = ProviderSource.podcast
    let inbox: SharedQueueInbox
    let expectedAcknowledgedShareID: UUID

    func canResolve(_ url: URL) -> Bool {
        url.host == "podcasts.example"
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard try !inbox.pending().contains(where: {
            $0.id == expectedAcknowledgedShareID
        }) else {
            throw ProviderResolutionError.malformedResponse(
                "The durable pending share was not acknowledged before resolution."
            )
        }

        return ProviderResolvedItem(
            originalURL: url,
            canonicalURL: url,
            title: "Durable episode",
            creatorName: "Test Show",
            artworkURL: nil,
            duration: 600,
            publishedAt: nil,
            source: .podcast,
            playback: .remoteAudio(
                URL(string: "https://cdn.example.com/durable.mp3")!
            ),
            isMadeForKids: false
        )
    }
}

private actor SharedInboxResolutionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendFirstResolution() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct DelayedSharedInboxProvider: MediaProvider {
    let source = ProviderSource.podcast
    let inbox: SharedQueueInbox
    let gate: SharedInboxResolutionGate

    func canResolve(_ url: URL) -> Bool {
        url.host == "podcasts.example"
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard try inbox.pending().isEmpty else {
            throw ProviderResolutionError.malformedResponse(
                "Every receipt should be acknowledged before network resolution."
            )
        }
        if url.lastPathComponent == "first" {
            await gate.suspendFirstResolution()
        }
        return ProviderResolvedItem(
            originalURL: url,
            canonicalURL: url,
            title: "Resolved \(url.lastPathComponent)",
            creatorName: "Test Show",
            artworkURL: nil,
            duration: 600,
            publishedAt: nil,
            source: .podcast,
            playback: .remoteAudio(
                URL(
                    string: "https://cdn.example.com/\(url.lastPathComponent).mp3"
                )!
            ),
            isMadeForKids: false
        )
    }
}
