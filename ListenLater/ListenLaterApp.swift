import SwiftData
import SwiftUI

@main
struct ListenLaterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let isDemoMode = ProcessInfo.processInfo.arguments.contains("-DemoQueue")
        let persistence: PersistenceController.Result
        do {
            persistence = try PersistenceController.makeContainer(inMemory: isDemoMode)
        } catch {
            fatalError("Unable to create the Listen Later store: \(error)")
        }

        container = persistence.container
        _model = State(
            initialValue: AppModel(
                persistence: persistence,
                isDemoMode: isDemoMode
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

