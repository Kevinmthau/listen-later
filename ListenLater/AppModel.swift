import CoreData
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

    /// How often the queue is re-read in case a change notification was
    /// missed. Changes normally arrive through notifications.
    static let safetyNetRefreshInterval: Duration = .seconds(30)

    private var hasStarted = false
    @ObservationIgnored private var metadataMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var queueObservationTask: Task<Void, Never>?
    @ObservationIgnored private var storeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var storeChangeRefreshTask: Task<Void, Never>?
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
        storeChangeRefreshTask?.cancel()
        storeChangeRefreshTask = nil
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
            self.storeChangeObserver = nil
        }
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

    /// While the app is active, re-reads the queue when the store reports a
    /// change, such as a CloudKit import from another device, rather than
    /// polling it. Shares from the extension have their own notification.
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
                self.queue.refresh()
                await self.queue.importPendingShares()
                self.playback.reconcileQueueState()
            }
        }
    }

    /// Imports arrive in bursts, one notification per transaction, and this
    /// app's own saves can post them too, so refresh at most every half
    /// second rather than once per notification.
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
            self.queue.refresh()
            self.playback.reconcileQueueState()
        }
    }
}
