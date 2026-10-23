import Foundation
import SwiftData
import XCTest
#if os(iOS)
@testable import ListenLater
#endif

final class PersistenceControllerTests: XCTestCase {
    func testInMemoryNeverResolvesPersonalStoreLocations() throws {
        let result = try PersistenceController.makeContainer(
            inMemory: true,
            resolveLocations: {
                XCTFail("An in-memory test must not inspect the personal queue")
                return .init(sandbox: URL(fileURLWithPath: "/unused"), appGroup: nil)
            },
            resolveCloudKitContainerIdentifier: {
                XCTFail("An in-memory test must not resolve iCloud entitlements")
                return nil
            }
        )
        XCTAssertFalse(result.isCloudBacked)
        XCTAssertNil(result.fallbackReason)
        let configuration = try XCTUnwrap(result.container.configurations.first)
        XCTAssertTrue(configuration.isStoredInMemoryOnly)
        XCTAssertNil(configuration.cloudKitContainerIdentifier)
        XCTAssertNil(configuration.groupAppContainerIdentifier)
    }

    func testMissingAppGroupStillAttemptsPrivateCloudKitInSandbox() throws {
        try withStores { stores in
            var attempts: [ModelConfiguration] = []
            let result = try PersistenceController.makeContainer(
                resolveLocations: { .init(sandbox: stores.sandbox, appGroup: nil) },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: { schema, configuration in
                    attempts.append(configuration)
                    return try localContainer(schema, configuration)
                }
            )
            XCTAssertTrue(result.isCloudBacked)
            XCTAssertNil(result.fallbackReason)
            XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts.first?.url, stores.sandbox)
            XCTAssertEqual(attempts.first?.name, "ListenLaterSandbox")
            XCTAssertEqual(
                attempts.first?.cloudKitContainerIdentifier,
                AppConfiguration.iCloudContainerIdentifier
            )
            XCTAssertNil(attempts.first?.groupAppContainerIdentifier)
        }
    }

    func testMissingOrMismatchedICloudEntitlementOpensOnlyLocalStoreAndPreservesLinks() throws {
        for entitlement in [nil, "iCloud.com.example.Unrelated"] as [String?] {
            try withStores { stores in
                let link = snapshot(title: "Saved before signing", updated: 20, progress: 15)
                try seed(stores.sandbox, items: [link])
                var attempts: [ModelConfiguration] = []
                let result = try PersistenceController.makeContainer(
                    resolveLocations: { .init(sandbox: stores.sandbox, appGroup: nil) },
                    resolveCloudKitContainerIdentifier: { entitlement },
                    makeModelContainer: { schema, configuration in
                        attempts.append(configuration)
                        return try localContainer(schema, configuration)
                    }
                )
                XCTAssertFalse(result.isCloudBacked)
                XCTAssertTrue(result.fallbackReason?.contains("signed iCloud entitlement") == true)
                XCTAssertEqual(attempts.count, 1)
                XCTAssertNil(attempts.first?.cloudKitContainerIdentifier)
                XCTAssertEqual(attempts.first?.url, stores.sandbox)
                let context = ModelContext(result.container)
                let items = try context.fetch(FetchDescriptor<QueueItem>())
                XCTAssertEqual(items.map(\.id), [link.id])
                XCTAssertEqual(items.first?.title, link.title)
                XCTAssertEqual(items.first?.playbackPosition, link.playbackPosition)
            }
        }
    }

    func testCloudFailureAndLaterRecoveryUseSameStoreAndPreserveLinks() throws {
        try withStores { stores in
            let link = snapshot(title: "Added offline", updated: 20, progress: 15)
            var attempts: [ModelConfiguration] = []
            try autoreleasepool {
                let result = try PersistenceController.makeContainer(
                    resolveLocations: { .init(sandbox: stores.sandbox, appGroup: nil) },
                    resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                    makeModelContainer: { schema, configuration in
                        attempts.append(configuration)
                        if configuration.cloudKitContainerIdentifier != nil {
                            throw TestError.cloudUnavailable
                        }
                        return try localContainer(schema, configuration)
                    }
                )
                XCTAssertFalse(result.isCloudBacked)
                XCTAssertNotNil(result.fallbackReason)
                let context = ModelContext(result.container)
                let item = try XCTUnwrap(link.makeItem())
                item.updatedAt = link.updatedAt
                context.insert(item)
                try context.save()
            }
            XCTAssertEqual(attempts.map(\.url), [stores.sandbox, stores.sandbox])
            XCTAssertEqual(attempts.map(\.name), ["ListenLaterSandbox", "ListenLaterSandbox"])
            XCTAssertNotNil(attempts[0].cloudKitContainerIdentifier)
            XCTAssertNil(attempts[1].cloudKitContainerIdentifier)

            // App Group access is restored, but there is no established group
            // queue. Continue mirroring the queue that contains the offline link.
            let recovered = try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: localContainer
            )
            XCTAssertTrue(recovered.isCloudBacked)
            XCTAssertEqual(recovered.container.configurations.first?.url, stores.sandbox)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stores.appGroup!.path))
            let recoveredContext = ModelContext(recovered.container)
            let items = try recoveredContext.fetch(FetchDescriptor<QueueItem>())
            XCTAssertEqual(items.map(\.id), [link.id])
            XCTAssertEqual(items.first?.originalURLString, link.originalURLString)
            XCTAssertEqual(items.first?.playbackPosition, link.playbackPosition)
            XCTAssertEqual(items.first?.updatedAt, link.updatedAt)
        }
    }

    func testMirroredSandboxKeepsItsCloudIdentityWhenExistingGroupReturns() throws {
        try withStores { stores in
            let link = snapshot(title: "Sandbox cloud identity", updated: 20, progress: 15)
            try seed(stores.sandbox, items: [link])
            try autoreleasepool {
                let initialLaunch = try PersistenceController.makeContainer(
                    resolveLocations: { .init(sandbox: stores.sandbox, appGroup: nil) },
                    resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                    makeModelContainer: localContainer
                )
                XCTAssertTrue(initialLaunch.isCloudBacked)
            }
            // The group has an older copy of the same cloud-backed link. Its
            // store was inaccessible while the sandbox began mirroring.
            try seed(stores.appGroup!, items: [snapshot(id: link.id, title: "Group copy", updated: 10, progress: 5)])
            var openedURLs: [URL] = []
            let returnedGroup = try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: { schema, configuration in
                    openedURLs.append(configuration.url)
                    return try localContainer(schema, configuration)
                }
            )
            XCTAssertTrue(returnedGroup.isCloudBacked)
            XCTAssertTrue(returnedGroup.fallbackReason?.contains("cannot be merged automatically") == true)
            XCTAssertEqual(openedURLs, [stores.sandbox])
            let context = ModelContext(returnedGroup.container)
            let items = try context.fetch(FetchDescriptor<QueueItem>())
            XCTAssertEqual(items.map(\.id), [link.id])
            XCTAssertEqual(items.first?.title, link.title)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: stores.appGroup!.appendingPathExtension("recovery.json").path
            ))
        }
    }

    func testEstablishedGroupUsesLocalFallbackAndRecoversBothQueuesWhenAccessReturns() throws {
        for initialEntitlement in [AppConfiguration.iCloudContainerIdentifier, nil] as [String?] {
            try withStores { stores in
                let groupLink = snapshot(title: "Original group link", updated: 20, progress: 10)
                let fallbackLink = snapshot(title: "Added during lost group access", updated: 30, progress: 15)
                try seed(stores.appGroup!, items: [groupLink])
                try autoreleasepool {
                    let original = try PersistenceController.makeContainer(
                        resolveLocations: { stores },
                        resolveCloudKitContainerIdentifier: { initialEntitlement },
                        makeModelContainer: localContainer
                    )
                    XCTAssertEqual(original.isCloudBacked, initialEntitlement != nil)
                    XCTAssertEqual(original.container.configurations.first?.url, stores.appGroup)
                }
                try autoreleasepool {
                    var attempts: [ModelConfiguration] = []
                    let unavailableGroup = try PersistenceController.makeContainer(
                        resolveLocations: { .init(sandbox: stores.sandbox, appGroup: nil) },
                        resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                        makeModelContainer: { schema, configuration in
                            attempts.append(configuration)
                            return try localContainer(schema, configuration)
                        }
                    )
                    XCTAssertFalse(unavailableGroup.isCloudBacked)
                    XCTAssertTrue(unavailableGroup.fallbackReason?.contains("existing iCloud queue is unavailable") == true)
                    XCTAssertEqual(attempts.count, 1)
                    XCTAssertNil(attempts.first?.cloudKitContainerIdentifier)
                    XCTAssertEqual(attempts.first?.url, stores.sandbox)
                    let context = ModelContext(unavailableGroup.container)
                    let item = try XCTUnwrap(fallbackLink.makeItem())
                    item.updatedAt = fallbackLink.updatedAt
                    context.insert(item)
                    try context.save()
                    XCTAssertFalse(FileManager.default.fileExists(
                        atPath: stores.sandbox.appendingPathExtension("cloudkit").path
                    ))
                }
                let recovered = try PersistenceController.makeContainer(
                    resolveLocations: { stores },
                    resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                    makeModelContainer: localContainer
                )
                XCTAssertTrue(recovered.isCloudBacked)
                XCTAssertNil(recovered.fallbackReason)
                XCTAssertEqual(recovered.container.configurations.first?.url, stores.appGroup)
                let context = ModelContext(recovered.container)
                let items = try context.fetch(FetchDescriptor<QueueItem>())
                XCTAssertEqual(Set(items.map(\.id)), [groupLink.id, fallbackLink.id])
                XCTAssertEqual(items.first { $0.id == groupLink.id }?.title, groupLink.title)
                XCTAssertEqual(items.first { $0.id == fallbackLink.id }?.title, fallbackLink.title)
            }
        }
    }

    func testGroupSelectionMarkerFailureKeepsHealthyGroupLocalWithDiagnostic() throws {
        try withStores { stores in
            let link = snapshot(title: "Group link", updated: 20, progress: 10)
            try seed(stores.appGroup!, items: [link])
            let blockedParent = stores.sandbox.deletingLastPathComponent().appendingPathComponent("NotADirectory")
            try Data("file blocks directory creation".utf8).write(to: blockedParent)
            let blockedLocations = PersistenceController.StoreLocations(
                sandbox: blockedParent.appendingPathComponent("Sandbox.store"),
                appGroup: stores.appGroup
            )
            var attempts: [ModelConfiguration] = []
            let result = try PersistenceController.makeContainer(
                resolveLocations: { blockedLocations },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: { schema, configuration in
                    attempts.append(configuration)
                    return try localContainer(schema, configuration)
                }
            )
            XCTAssertFalse(result.isCloudBacked)
            XCTAssertTrue(result.fallbackReason?.contains("could not safely initialize") == true)
            XCTAssertEqual(attempts.count, 1)
            XCTAssertNil(attempts.first?.cloudKitContainerIdentifier)
            XCTAssertEqual(attempts.first?.url, stores.appGroup)
            let context = ModelContext(result.container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QueueItem>()).map(\.id), [link.id])
        }
    }

    func testNewQueueUsesAvailableAppGroup() throws {
        try withStores { stores in
            let result = try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: localContainer
            )
            XCTAssertEqual(result.container.configurations.first?.url, stores.appGroup)
            XCTAssertEqual(result.container.configurations.first?.name, "ListenLater")
        }
    }

    func testBothLegacyStoresRecoverWithoutReplacingNewerMetadataOrProgress() throws {
        try withStores { stores in
            let commonID = UUID()
            let otherCommonID = UUID()
            let groupNewestMetadata = snapshot(id: commonID, title: "Synced title", updated: 30, progress: 10)
            let sandboxNewestProgress = snapshot(id: commonID, title: "Old title", updated: 20, progress: 15)
            let groupNewestProgress = snapshot(id: otherCommonID, title: "Old group title", updated: 20, progress: 15)
            let sandboxNewestMetadata = snapshot(id: otherCommonID, title: "Recovered title", updated: 30, progress: 10)
            let groupOnly = snapshot(title: "Group only", updated: 40, progress: 20)
            let sandboxOnly = snapshot(title: "Sandbox only", updated: 25, progress: 12)
            try seed(stores.appGroup!, items: [groupNewestMetadata, groupNewestProgress, groupOnly])
            try seed(stores.sandbox, items: [sandboxNewestProgress, sandboxNewestMetadata, sandboxOnly])

            try autoreleasepool {
                let result = try PersistenceController.makeContainer(
                    resolveLocations: { stores },
                    resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                    makeModelContainer: localContainer
                )
                XCTAssertEqual(result.container.configurations.first?.url, stores.appGroup)
                let context = ModelContext(result.container)
                let items = try context.fetch(FetchDescriptor<QueueItem>())
                XCTAssertEqual(Set(items.map(\.id)), [commonID, otherCommonID, groupOnly.id, sandboxOnly.id])
                let common = try XCTUnwrap(items.first { $0.id == commonID })
                XCTAssertEqual(common.title, "Synced title")
                XCTAssertEqual(common.updatedAt, groupNewestMetadata.updatedAt)
                XCTAssertEqual(common.progressUpdatedAt, sandboxNewestProgress.progressUpdatedAt)
                XCTAssertEqual(common.playbackPosition, sandboxNewestProgress.playbackPosition)
                let other = try XCTUnwrap(items.first { $0.id == otherCommonID })
                XCTAssertEqual(other.title, "Recovered title")
                XCTAssertEqual(other.progressUpdatedAt, groupNewestProgress.progressUpdatedAt)
                XCTAssertEqual(other.playbackPosition, groupNewestProgress.playbackPosition)
                let recovered = try XCTUnwrap(items.first { $0.id == sandboxOnly.id })
                XCTAssertEqual(recovered.updatedAt, sandboxOnly.updatedAt)
                XCTAssertEqual(recovered.createdAt, sandboxOnly.createdAt)
                // A later deletion must not be undone by an untouched legacy copy.
                context.delete(recovered)
                try context.save()
            }
            try autoreleasepool {
                let secondLaunch = try PersistenceController.makeContainer(
                    resolveLocations: { stores },
                    resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                    makeModelContainer: localContainer
                )
                let context = ModelContext(secondLaunch.container)
                let items = try context.fetch(FetchDescriptor<QueueItem>())
                XCTAssertEqual(items.count, 3)
                XCTAssertFalse(items.contains { $0.id == sandboxOnly.id })
            }
            // Recovery never changes or removes the old store.
            let original = try snapshots(at: stores.sandbox)
            XCTAssertEqual(original.count, 3)
            XCTAssertEqual(original.first { $0.id == commonID }?.title, "Old title")
        }
    }

    func testEqualProgressTimestampUsesNewerQueueStateForRequeuedLink() throws {
        try withStores { stores in
            let id = UUID()
            let original = snapshot(id: id, title: "Played", updated: 20, progress: 10)
            let played = try XCTUnwrap(original.makeItem())
            played.isPlayed = true
            played.lastPlayedAt = Date(timeIntervalSince1970: 10)
            played.updatedAt = original.updatedAt
            let requeued = try XCTUnwrap(original.makeItem())
            requeued.isPlayed = false
            requeued.playbackPosition = 0
            requeued.lastPlayedAt = nil
            requeued.updatedAt = Date(timeIntervalSince1970: 30)
            try seed(stores.appGroup!, items: [played.snapshot()])
            try seed(stores.sandbox, items: [requeued.snapshot()])
            let result = try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: localContainer
            )
            let context = ModelContext(result.container)
            let item = try XCTUnwrap(context.fetch(FetchDescriptor<QueueItem>()).first)
            XCTAssertFalse(item.isPlayed)
            XCTAssertNil(item.lastPlayedAt)
            XCTAssertEqual(item.playbackPosition, 0)
            XCTAssertEqual(item.progressUpdatedAt, original.progressUpdatedAt)
        }
    }

    func testUnreadableLegacyStoreLeavesHealthyPrimaryAvailableWithNotice() throws {
        try withStores { stores in
            let link = snapshot(title: "Healthy group", updated: 20, progress: 10)
            try seed(stores.appGroup!, items: [link])
            try Data("Unreadable previous store".utf8).write(to: stores.sandbox)
            let result = try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: { schema, configuration in
                    if !configuration.allowsSave { throw CocoaError(.fileReadCorruptFile) }
                    return try localContainer(schema, configuration)
                }
            )
            XCTAssertTrue(result.isCloudBacked)
            XCTAssertNotNil(result.fallbackReason)
            let context = ModelContext(result.container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QueueItem>()).map(\.id), [link.id])
            XCTAssertEqual(try Data(contentsOf: stores.sandbox), Data("Unreadable previous store".utf8))
        }
    }

    func testCorruptRecoveryReceiptDoesNotHideHealthyPrimary() throws {
        try withStores { stores in
            let link = snapshot(title: "Healthy group", updated: 20, progress: 10)
            try seed(stores.appGroup!, items: [link])
            try seed(stores.sandbox, items: [snapshot(title: "Legacy", updated: 15, progress: 5)])
            try Data("Invalid receipt".utf8).write(to: stores.appGroup!.appendingPathExtension("recovery.json"))
            let result = try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: localContainer
            )
            XCTAssertTrue(result.isCloudBacked)
            XCTAssertNotNil(result.fallbackReason)
            let context = ModelContext(result.container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QueueItem>()).map(\.id), [link.id])
        }
    }

    func testUnavailablePrimaryStoreDoesNotSilentlyCreateAnotherQueue() throws {
        try withStores { stores in
            var attempts: [URL] = []
            XCTAssertThrowsError(try PersistenceController.makeContainer(
                resolveLocations: { stores },
                resolveCloudKitContainerIdentifier: { AppConfiguration.iCloudContainerIdentifier },
                makeModelContainer: { _, configuration in
                    attempts.append(configuration.url)
                    throw TestError.cloudUnavailable
                }
            ))
            XCTAssertEqual(attempts, [stores.appGroup!, stores.appGroup!])
            XCTAssertFalse(FileManager.default.fileExists(atPath: stores.sandbox.path))
        }
    }
}

private enum TestError: Error { case cloudUnavailable }

/// The production decision about CloudKit is observable, but these tests
/// always open local stores and never contact an iCloud account.
private func localContainer(_ schema: Schema, _ configuration: ModelConfiguration) throws -> ModelContainer {
    let local = ModelConfiguration(
        configuration.name,
        schema: schema,
        url: configuration.url,
        allowsSave: configuration.allowsSave,
        cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [local])
}

private func withStores(_ body: (PersistenceController.StoreLocations) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersistenceTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(.init(
        sandbox: root.appendingPathComponent("ListenLaterSandbox.store"),
        appGroup: root.appendingPathComponent("ListenLater.store")
    ))
}

private func snapshot(id: UUID = UUID(), title: String, updated: TimeInterval, progress: TimeInterval) -> QueueItemSnapshot {
    let item = QueueItem(
        id: id,
        originalURL: URL(string: "https://example.com/episode/\(id)")!,
        title: title,
        source: .podcast,
        status: .ready,
        sortRank: 1_000,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    item.updatedAt = Date(timeIntervalSince1970: updated)
    item.progressUpdatedAt = Date(timeIntervalSince1970: progress)
    item.playbackPosition = progress
    return item.snapshot()
}

private func seed(_ url: URL, items: [QueueItemSnapshot]) throws {
    try autoreleasepool {
        let schema = Schema([QueueItem.self])
        let container = try localContainer(schema, ModelConfiguration("Seed", schema: schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        for snapshot in items {
            let item = try XCTUnwrap(snapshot.makeItem())
            item.updatedAt = snapshot.updatedAt
            context.insert(item)
        }
        try context.save()
    }
}

private func snapshots(at url: URL) throws -> [QueueItemSnapshot] {
    try autoreleasepool {
        let schema = Schema([QueueItem.self])
        let container = try localContainer(schema, ModelConfiguration("Read", schema: schema, url: url, cloudKitDatabase: .none))
        return try ModelContext(container).fetch(FetchDescriptor<QueueItem>()).map { $0.snapshot() }
    }
}
