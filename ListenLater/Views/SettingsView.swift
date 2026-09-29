import SwiftUI

struct SettingsView: View {
    let isCloudBacked: Bool
    /// Why the queue isn't syncing, when it isn't.
    let persistenceNotice: String?
    let youtubeIsConfigured: Bool
    let videoGrabberIsConfigured: Bool
    /// The most recent problem the queue recorded, for troubleshooting.
    let lastFailure: String?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(PlaybackPreferences.videosWaitForScreenKey)
    private var videosWaitForScreen = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $videosWaitForScreen) {
                        Label("Save Videos for the Screen", systemImage: "iphone")
                    }
                } header: {
                    Text("When Locked")
                } footer: {
                    Text(
                        videosWaitForScreen
                            ? "While your iPhone is locked or MushRadio is in the background, the queue plays podcasts and leaves videos in Up Next for when you can watch them."
                            : "While your iPhone is locked, X and Instagram videos play as audio and are marked played when they end."
                    )
                }

                Section("Playback") {
                    Label(
                        "Podcasts continue in the background and use lock-screen and Bluetooth controls.",
                        systemImage: "headphones"
                    )
                    Label(
                        "X and Instagram videos are resolved by your video-grabber service and play in the app.",
                        systemImage: "play.square.stack"
                    )
                    Label(
                        "YouTube videos use the official visible player and pause when this app is not on screen.",
                        systemImage: "play.rectangle"
                    )
                }

                Section {
                    LabeledContent {
                        Text(isCloudBacked ? "On" : "Off")
                            .foregroundStyle(isCloudBacked ? Color.secondary : Color.orange)
                    } label: {
                        Label("iCloud Sync", systemImage: isCloudBacked ? "icloud" : "icloud.slash")
                    }
                } footer: {
                    Text(syncFooter)
                }

                Section {
                    DisclosureGroup("Diagnostics") {
                        LabeledContent("YouTube API key", value: youtubeIsConfigured ? "Set" : "Missing")
                        LabeledContent(
                            "Video resolver token",
                            value: videoGrabberIsConfigured ? "Set" : "Missing"
                        )
                        if let persistenceNotice {
                            diagnostic("Sync", persistenceNotice)
                        }
                        if let lastFailure {
                            diagnostic("Last problem", lastFailure)
                        }
                    }
                } footer: {
                    Text("Keys and tokens come from the build’s Secrets.xcconfig.")
                }

                Section("YouTube Terms & Privacy") {
                    Text(
                        "YouTube playback is provided by YouTube. Using it is subject to the YouTube Terms of Service, and Google’s Privacy Policy describes how Google handles data."
                    )
                    Link(
                        "YouTube Terms of Service",
                        destination: URL(string: "https://www.youtube.com/t/terms")!
                    )
                    Link(
                        "Google Privacy Policy",
                        destination: URL(string: "https://policies.google.com/privacy")!
                    )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var syncFooter: String {
        if isCloudBacked {
            return "Your queue and listening progress sync with your other devices signed in to the same iCloud account."
        }
        if persistenceNotice != nil {
            return "Your queue is saved on this device only. Diagnostics shows why."
        }
        return "Your queue is saved on this device only."
    }

    private func diagnostic(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
