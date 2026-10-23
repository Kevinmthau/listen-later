import Foundation
import SwiftData

enum AppConfiguration {
    static let appGroupIdentifier =
        Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
        ?? "group.com.kevinthau.ListenLater"

    static let iCloudContainerIdentifier =
        Bundle.main.object(forInfoDictionaryKey: "ICLOUD_CONTAINER_IDENTIFIER") as? String
        ?? "iCloud.com.kevinthau.ListenLater"

    static let youtubeAPIKey: String = {
        #if os(macOS)
        // The checked-in credential setup is restricted to the iOS bundle.
        // macOS deliberately uses public oEmbed metadata and external
        // YouTube playback rather than weakening that restriction.
        return ""
        #else
        let value = Bundle.main.object(forInfoDictionaryKey: "YOUTUBE_API_KEY") as? String
        return YouTubeAPIConfiguration(apiKey: value ?? "").apiKey
        #endif
    }()

    static let videoGrabberEndpoint: URL = {
        let value =
            Bundle.main.object(forInfoDictionaryKey: "VIDEO_GRABBER_ENDPOINT") as? String
        return value.flatMap(URL.init(string:))
            ?? VideoGrabberConfiguration.defaultEndpoint
    }()

    static let videoGrabberAPIToken: String = {
        let value =
            Bundle.main.object(forInfoDictionaryKey: "VIDEO_GRABBER_API_TOKEN") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }()
}

enum PersistenceController {
    struct Result {
        let container: ModelContainer
        let isCloudBacked: Bool
        let fallbackReason: String?
    }

    /// URLs are resolved separately from opening stores so tests never touch
    /// the app's real queue, App Group, or iCloud account.
    struct StoreLocations {
        let sandbox: URL
        let appGroup: URL?
    }

    typealias ContainerFactory = (Schema, ModelConfiguration) throws -> ModelContainer

    static func makeContainer(
        inMemory: Bool = false,
        resolveLocations: (() -> StoreLocations)? = nil,
        resolveCloudKitContainerIdentifier: (() -> String?)? = nil,
        makeModelContainer: ContainerFactory = { schema, configuration in
            try ModelContainer(for: schema, configurations: [configuration])
        }
    ) throws -> Result {
        let schema = Schema([QueueItem.self])
        if inMemory {
            let configuration = ModelConfiguration(
                "ListenLaterTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
            return Result(
                container: try makeModelContainer(schema, configuration),
                isCloudBacked: false,
                fallbackReason: nil
            )
        }

        let locations = resolveLocations?() ?? storeLocations(schema: schema)
        let sandboxExists = FileManager.default.fileExists(atPath: locations.sandbox.path)
        let groupExists = locations.appGroup.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let sandboxMarker = locations.sandbox.appendingPathExtension("cloudkit")
        // This selection lives outside the App Group so it remains readable
        // if signing or container access temporarily makes the group vanish.
        let groupMarker = locations.sandbox.appendingPathExtension("group-cloudkit")
        let hasEstablishedGroup = FileManager.default.fileExists(atPath: groupMarker.path)
        let hasMirroredSandbox = sandboxExists
            && FileManager.default.fileExists(atPath: sandboxMarker.path)
        // Once a sandbox store has mirrored, its CloudKit record identities
        // must remain intact. Copying those rows into an established group
        // would race CloudKit imports and create duplicate remote records.
        // An unmarked legacy fallback can still recover into the group.
        let useGroup = !hasMirroredSandbox
            && (groupExists || (locations.appGroup != nil && (hasEstablishedGroup || !sandboxExists)))
        let storeURL = useGroup ? locations.appGroup! : locations.sandbox
        let name = useGroup ? "ListenLater" : "ListenLaterSandbox"

        // Read a stranded fallback before opening the destination, so two
        // independent live containers never own the QueueItem model together.
        var recovery: Recovery?
        var recoveryNotice: String?
        if hasMirroredSandbox, groupExists, locations.appGroup != locations.sandbox {
            recoveryNotice = "An older queue is also saved in the App Group and cannot be merged automatically with this iCloud queue. Its original data is preserved. This app continues syncing the current queue."
        } else if useGroup, sandboxExists, locations.sandbox != storeURL {
            do {
                recovery = try readRecovery(
                    sourceURL: locations.sandbox,
                    destinationURL: storeURL,
                    schema: schema,
                    factory: makeModelContainer
                )
            } catch {
                recoveryNotice = "Some links saved in the previous local queue could not be recovered. Its original store is preserved. \(error.localizedDescription)"
            }
        }

        // Explicit CloudKit configuration in an unsigned/mis-signed build
        // can crash asynchronously, beyond the reach of do/catch. Ask
        // SwiftData to resolve the signed entitlement before enabling it.
        let entitledContainer: String?
        if let resolveCloudKitContainerIdentifier {
            entitledContainer = resolveCloudKitContainerIdentifier()
        } else {
            entitledContainer = ModelConfiguration(
                schema: schema,
                groupContainer: .none,
                cloudKitDatabase: .automatic
            ).cloudKitContainerIdentifier
        }
        let localConfiguration = ModelConfiguration(
            name,
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        var configurationNotice: String?
        var createdSandboxMarker = false
        if useGroup, !hasEstablishedGroup {
            do {
                // Preserve the primary selection even in a locally signed
                // build. Its group queue may contain links not yet exported.
                try writeSelectionMarker(at: groupMarker)
            } catch {
                configurationNotice = "iCloud sync could not safely initialize this queue. Links remain saved on this device. \(error.localizedDescription)"
            }
        }
        if configurationNotice == nil {
            if hasEstablishedGroup, !useGroup, !hasMirroredSandbox {
                // Do not create a second cloud identity while the original
                // group is inaccessible. Its local fallback is recovered when
                // the original store becomes available again.
                configurationNotice = "The App Group containing your existing iCloud queue is unavailable. New links are saved on this device and will be recovered into that queue when App Group access returns."
            } else if entitledContainer != AppConfiguration.iCloudContainerIdentifier {
                configurationNotice = "This build is missing the signed iCloud entitlement for \(AppConfiguration.iCloudContainerIdentifier). Links are saved on this device until a correctly signed build is installed."
            } else if !useGroup, !hasMirroredSandbox {
                do {
                    // Record the chosen cloud identity before asynchronous
                    // exports can start. Failure leaves the queue local.
                    try writeSelectionMarker(at: sandboxMarker)
                    createdSandboxMarker = true
                } catch {
                    configurationNotice = "iCloud sync could not safely initialize this queue. Links remain saved on this device. \(error.localizedDescription)"
                }
            }
        }
        let container: ModelContainer
        let cloudBacked: Bool
        let fallbackReason: String?
        if let configurationNotice {
            container = try makeModelContainer(schema, localConfiguration)
            cloudBacked = false
            fallbackReason = configurationNotice
        } else {
            do {
                container = try makeModelContainer(schema, ModelConfiguration(
                    name,
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .private(AppConfiguration.iCloudContainerIdentifier)
                ))
                cloudBacked = true
                fallbackReason = nil
            } catch {
                fallbackReason = error.localizedDescription
                if createdSandboxMarker {
                    // A synchronous failure never established mirroring. A
                    // marker from an earlier launch must always be retained.
                    try? FileManager.default.removeItem(at: sandboxMarker)
                }
                // Retry the exact same durable store without mirroring. A
                // later successful launch exports links added while offline.
                // Propagate a second failure instead of showing an empty queue.
                container = try makeModelContainer(schema, localConfiguration)
                cloudBacked = false
            }
        }
        if let recovery {
            do {
                try applyRecovery(recovery, to: container)
            } catch {
                recoveryNotice = "Recovery of the previous local queue could not finish. Its original store is preserved and recovery will be retried. \(error.localizedDescription)"
            }
        }
        let notices = [fallbackReason, recoveryNotice].compactMap { $0 }
        return Result(
            container: container,
            isCloudBacked: cloudBacked,
            fallbackReason: notices.isEmpty ? nil : notices.joined(separator: "\n")
        )
    }

    private static func writeSelectionMarker(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(AppConfiguration.iCloudContainerIdentifier.utf8).write(
            to: url,
            options: .atomic
        )
    }

    private static func storeLocations(schema: Schema) -> StoreLocations {
        let sandbox = ModelConfiguration(
            "ListenLaterSandbox",
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        ).url
        // Naming an unavailable App Group can terminate SwiftData instead of
        // throwing. It determines local storage only, not iCloud eligibility.
        let appGroup: URL?
        if FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) != nil {
            appGroup = ModelConfiguration(
                "ListenLater",
                schema: schema,
                groupContainer: .identifier(AppConfiguration.appGroupIdentifier),
                cloudKitDatabase: .none
            ).url
        } else {
            appGroup = nil
        }
        return StoreLocations(sandbox: sandbox, appGroup: appGroup)
    }

    private struct RecoveryVersion: Codable, Equatable {
        let updatedAt: Date
        let progressUpdatedAt: Date

        init(_ item: QueueItemSnapshot) {
            updatedAt = item.updatedAt
            progressUpdatedAt = item.progressUpdatedAt
        }
    }

    private struct Recovery {
        let items: [QueueItemSnapshot]
        let receiptURL: URL
        let receipts: [String: [String: RecoveryVersion]]
    }

    private static func readRecovery(
        sourceURL: URL,
        destinationURL: URL,
        schema: Schema,
        factory: ContainerFactory
    ) throws -> Recovery {
        let receiptURL = destinationURL.appendingPathExtension("recovery.json")
        var receipts: [String: [String: RecoveryVersion]] = [:]
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            receipts = try JSONDecoder().decode(
                [String: [String: RecoveryVersion]].self,
                from: Data(contentsOf: receiptURL)
            )
        }
        let snapshots: [QueueItemSnapshot] = try autoreleasepool {
            let source = try factory(schema, ModelConfiguration(
                "ListenLaterSandbox",
                schema: schema,
                url: sourceURL,
                allowsSave: false,
                cloudKitDatabase: .none
            ))
            let context = ModelContext(source)
            return try context.fetch(FetchDescriptor<QueueItem>()).map { $0.snapshot() }
        }
        var sourceReceipts = receipts[sourceURL.path] ?? [:]
        let pending = snapshots.filter {
            sourceReceipts[$0.id.uuidString] != RecoveryVersion($0)
        }
        for snapshot in pending {
            sourceReceipts[snapshot.id.uuidString] = RecoveryVersion(snapshot)
        }
        receipts[sourceURL.path] = sourceReceipts
        return Recovery(items: pending, receiptURL: receiptURL, receipts: receipts)
    }

    private static func applyRecovery(_ recovery: Recovery, to container: ModelContainer) throws {
        guard !recovery.items.isEmpty else { return }
        let context = ModelContext(container)
        var byID: [UUID: QueueItem] = [:]
        for item in try context.fetch(FetchDescriptor<QueueItem>()) {
            // CloudKit does not enforce UUID uniqueness. Preserve every
            // existing record and merge into the newest representative.
            if byID[item.id].map({ $0.updatedAt >= item.updatedAt }) != true {
                byID[item.id] = item
            }
        }
        for snapshot in recovery.items {
            if let existing = byID[snapshot.id] {
                merge(snapshot, into: existing)
            } else {
                guard let item = snapshot.makeItem() else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                item.updatedAt = snapshot.updatedAt
                context.insert(item)
                byID[item.id] = item
            }
        }
        try context.save()
        // Never remove the source store. Record recovered versions only after
        // the destination is durable, so retries are safe and an unchanged
        // legacy copy cannot resurrect a subsequently deleted queue item.
        try JSONEncoder().encode(recovery.receipts).write(
            to: recovery.receiptURL,
            options: .atomic
        )
    }

    private static func merge(_ snapshot: QueueItemSnapshot, into item: QueueItem) {
        let newerQueueState = snapshot.updatedAt > item.updatedAt
        if newerQueueState {
            item.originalURLString = snapshot.originalURLString
            item.canonicalURLString = snapshot.canonicalURLString
            item.playbackURLString = snapshot.playbackURLString
            item.playbackURLExpiresAt = snapshot.playbackURLExpiresAt
            item.youtubeVideoID = snapshot.youtubeVideoID
            item.pendingShareReceiptIDString = snapshot.pendingShareReceiptIDString
            item.localMediaIDString = snapshot.localMediaIDString
            item.localFilename = snapshot.localFilename
            item.localPosterFilename = snapshot.localPosterFilename
            item.localPixelWidth = snapshot.localPixelWidth
            item.localPixelHeight = snapshot.localPixelHeight
            item.title = snapshot.title
            item.subtitle = snapshot.subtitle
            item.artworkURLString = snapshot.artworkURLString
            item.duration = snapshot.duration
            item.sourceRawValue = snapshot.sourceRawValue
            item.statusRawValue = snapshot.statusRawValue
            item.unavailableReason = snapshot.unavailableReason
            item.metadataFetchedAt = snapshot.metadataFetchedAt
            item.youtubeEmbeddable = snapshot.youtubeEmbeddable
            item.youtubeMadeForKids = snapshot.youtubeMadeForKids
            item.sortRank = snapshot.sortRank
            item.updatedAt = snapshot.updatedAt
        }
        if snapshot.progressUpdatedAt > item.progressUpdatedAt
            || (snapshot.progressUpdatedAt == item.progressUpdatedAt && newerQueueState) {
            item.playbackPosition = snapshot.playbackPosition
            item.playbackRate = snapshot.playbackRate
            item.isPlayed = snapshot.isPlayed
            item.lastPlayedAt = snapshot.lastPlayedAt
            item.progressUpdatedAt = snapshot.progressUpdatedAt
        }
    }
}
