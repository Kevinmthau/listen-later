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
        let value = Bundle.main.object(forInfoDictionaryKey: "YOUTUBE_API_KEY") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    static func makeContainer(inMemory: Bool = false) throws -> Result {
        let schema = Schema([QueueItem.self])
        if inMemory {
            let configuration = ModelConfiguration(
                "ListenLaterTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return Result(
                container: try ModelContainer(for: schema, configurations: [configuration]),
                isCloudBacked: false,
                fallbackReason: nil
            )
        }

        // SwiftData stops the process, rather than throwing, when a
        // configuration names an App Group the build isn't entitled to. Check
        // first so a signing mistake reaches the local fallback below.
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        ) != nil else {
            return Result(
                container: try makeSandboxContainer(schema: schema),
                isCloudBacked: false,
                fallbackReason:
                    "The App Group \(AppConfiguration.appGroupIdentifier) isn’t available to this build."
            )
        }

        do {
            let cloudConfiguration = ModelConfiguration(
                "ListenLater",
                schema: schema,
                groupContainer: .identifier(AppConfiguration.appGroupIdentifier),
                cloudKitDatabase: .private(AppConfiguration.iCloudContainerIdentifier)
            )
            let container = try ModelContainer(
                for: schema,
                configurations: [cloudConfiguration]
            )
            return Result(container: container, isCloudBacked: true, fallbackReason: nil)
        } catch {
            let cloudError = error
            do {
                let localConfiguration = ModelConfiguration(
                    // Keep the same App Group store identity so records written
                    // during a temporary CloudKit outage are mirrored when
                    // cloud initialization succeeds on a later launch.
                    "ListenLater",
                    schema: schema,
                    groupContainer: .identifier(AppConfiguration.appGroupIdentifier),
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(
                    for: schema,
                    configurations: [localConfiguration]
                )
                return Result(
                    container: container,
                    isCloudBacked: false,
                    fallbackReason: cloudError.localizedDescription
                )
            } catch {
                return Result(
                    container: try makeSandboxContainer(schema: schema),
                    isCloudBacked: false,
                    fallbackReason: "CloudKit: \(cloudError.localizedDescription) App Group: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func makeSandboxContainer(schema: Schema) throws -> ModelContainer {
        let sandboxConfiguration = ModelConfiguration(
            "ListenLaterSandbox",
            schema: schema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [sandboxConfiguration]
        )
    }
}
