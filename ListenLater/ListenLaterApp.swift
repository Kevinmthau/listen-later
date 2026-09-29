import SwiftData
import SwiftUI

@main
struct ListenLaterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let isDemoMode = ProcessInfo.processInfo.arguments.contains("-DemoQueue")
        // Unit tests run inside this app; keep them away from the real store
        // and the user's iCloud data. Tests build their own containers.
        let isHostingUnitTests =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let persistence: PersistenceController.Result
        do {
            persistence = try PersistenceController.makeContainer(
                inMemory: isDemoMode || isHostingUnitTests
            )
        } catch {
            fatalError("Unable to create the MushRadio store: \(error)")
        }

        container = persistence.container
        _model = State(
            initialValue: AppModel(
                persistence: persistence,
                // The test host also runs like demo mode, which never imports
                // from the App Group inbox: on a signed build, importing into
                // the in-memory store would consume real shared links.
                isDemoMode: isDemoMode || isHostingUnitTests
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            QueueScreen(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task { await model.sceneDidBecomeActive() }
                    case .inactive, .background:
                        model.sceneWillResignActive()
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(container)
    }
}
