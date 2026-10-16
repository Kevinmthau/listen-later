import SwiftData
import SwiftUI

@main
struct ListenLaterMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MacAppModel

    init() {
        let processInfo = ProcessInfo.processInfo
        let isTesting = processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processInfo.arguments.contains("-InMemoryStore")
        do {
            let shared = try PersistenceController.makeContainer(inMemory: isTesting)
            let local = try LocalQueueStore.makeContainer(inMemory: isTesting)
            let root: URL
            if isTesting {
                root = FileManager.default.temporaryDirectory
                    .appending(
                        path: "MushRadio-\(processInfo.processIdentifier)",
                        directoryHint: .isDirectory
                    )
            } else {
                let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!
                root = applicationSupport
                    .appending(path: "MushRadio", directoryHint: .isDirectory)
                    .appending(path: "LocalMedia", directoryHint: .isDirectory)
            }
            _model = State(initialValue: MacAppModel(
                sharedPersistence: shared,
                localContainer: local,
                localMediaLibrary: LocalMediaLibrary(root: root)
            ))
        } catch {
            fatalError("Could not initialize MushRadio storage: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.refresh() }
                    } else {
                        model.sceneWillResignActive()
                    }
                }
        }
        .defaultSize(width: 1_060, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Add Link…") {
                    model.presentedSheet = .addLink
                }
                .keyboardShortcut("n")

                Button("Import Videos…") {
                    model.isShowingImporter = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button(model.playback.state == .playing ? "Pause" : "Play") {
                    Task { await model.playback.playOrPause() }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next") {
                    Task { await model.playback.playNext() }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Delete") {
                    Task { await model.undoDeletion() }
                }
                .keyboardShortcut("z")
                .disabled(!model.canUndoDeletion)
            }
        }

        Settings {
            MacSettingsView(
                localMediaRoot: modelLocalMediaDescription,
                isCloudBacked: model.isCloudBacked,
                persistenceNotice: model.persistenceNotice
            )
        }
    }

    private var modelLocalMediaDescription: String {
        "Application Support/MushRadio/LocalMedia"
    }
}
