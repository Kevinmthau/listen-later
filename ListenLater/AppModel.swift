import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppModel {
    let queue: QueueStore
    let playback: PlaybackCoordinator
    let isCloudBacked: Bool
    let persistenceNotice: String?
    let isDemoMode: Bool

    private var hasStarted = false
    @ObservationIgnored private var metadataMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var queueObservationTask: Task<Void, Never>?
    @ObservationIgnored private var inboxObservation: SharedQueueInboxObservation?

    init(
        persistence: PersistenceController.Result,
        isDemoMode: Bool
    ) {
        self.isCloudBacked = persistence.isCloudBacked
        self.persistenceNotice = persistence.fallbackReason
        self.isDemoMode = isDemoMode

        let inbox = try? SharedQueueInbox(
            appGroupIdentifier: AppConfiguration.appGroupIdentifier
        )
        let providers = ProviderRegistry(
            youtubeAPIKey: AppConfiguration.youtubeAPIKey,
            videoGrabberEndpoint: AppConfiguration.videoGrabberEndpoint,
            videoGrabberAPIToken: AppConfiguration.videoGrabberAPIToken
        )
        let queue = QueueStore(
            context: persistence.container.mainContext,
            providers: providers,
            inbox: inbox
        )
        self.queue = queue
        playback = PlaybackCoordinator(queue: queue)

        if !isDemoMode, let inbox {
            inboxObservation = inbox.observeEnqueues { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.queue.refresh()
                    await self.queue.importPendingShares()
                    self.playback.reconcileQueueState()
                }
            }
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        if isDemoMode {
            queue.seedDemoDataIfNeeded()
            return
        }

        beginMetadataMaintenance()
        beginQueueObservation()
        await queue.resumePendingResolutions()
        await queue.importPendingShares()
        await queue.refreshExpiredYouTubeMetadata()
        playback.reconcileQueueState()
    }

    func sceneDidBecomeActive() async {
        if !isDemoMode {
            beginQueueObservation()
        }
        queue.refresh()
        // The coordinator reconciles as it returns to the foreground, so
        // anything that starts uses the on-screen rules, not the locked ones.
        playback.sceneDidBecomeActive()
        guard !isDemoMode else { return }
        await queue.resumePendingResolutions()
        await queue.importPendingShares()
        await queue.refreshExpiredYouTubeMetadata()
        playback.reconcileQueueState()
    }

    func sceneWillResignActive() {
        queueObservationTask?.cancel()
        queueObservationTask = nil
        playback.sceneWillResignActive()
    }

    private func beginMetadataMaintenance() {
        guard metadataMaintenanceTask == nil else { return }
        metadataMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch {
                    return
                }
                guard let self else { return }
                await self.queue.refreshExpiredYouTubeMetadata()
                self.playback.reconcileQueueState()
            }
        }
    }

    private func beginQueueObservation() {
        guard queueObservationTask == nil else { return }
        queueObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self else { return }
                self.queue.refresh()
                await self.queue.importPendingShares()
                self.playback.reconcileQueueState()
            }
        }
    }
}
