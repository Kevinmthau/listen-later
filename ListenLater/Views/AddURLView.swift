import SwiftUI

struct AddURLView: View {
    /// Adds the link and returns right away; the queue row shows progress.
    let add: (URL) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $urlString, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Podcast, X video, Instagram video, or YouTube link")
                        .onChange(of: urlString) { _, _ in
                            validationMessage = nil
                        }

                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        urlString = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } header: {
                    Text("Podcast or Video Link")
                } footer: {
                    Text("Podcast episode pages, Apple Podcasts episodes, YouTube, X and Instagram videos. Sharing from another app is quicker: choose “Add to Queue”.")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add to Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit)
                        .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        guard let url = LinkClassifier.link(fromUserText: urlString) else {
            validationMessage = "Enter a web link, such as https://example.com/episode."
            return
        }
        if case let .unsupported(reason) = LinkClassifier.classify(url) {
            validationMessage = reason
            return
        }
        if add(url) {
            dismiss()
        } else {
            validationMessage = "This link couldn’t be added. Try again."
        }
    }
}

struct PlaybackInfoView: View {
    let isCloudBacked: Bool
    let persistenceNotice: String?
    let youtubeIsConfigured: Bool
    let videoGrabberIsConfigured: Bool

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

                Section("Status") {
                    LabeledContent("CloudKit sync") {
                        Label(
                            isCloudBacked ? "Active" : "Local only",
                            systemImage: isCloudBacked ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .foregroundStyle(isCloudBacked ? .green : .orange)
                    }
                    LabeledContent("YouTube API") {
                        Text(youtubeIsConfigured ? "Configured" : "Key required")
                            .foregroundStyle(youtubeIsConfigured ? .green : .orange)
                    }
                    LabeledContent("Social video resolver") {
                        Text(videoGrabberIsConfigured ? "Configured" : "Token required")
                            .foregroundStyle(videoGrabberIsConfigured ? .green : .orange)
                    }
                    if let persistenceNotice, !isCloudBacked {
                        Text(persistenceNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            .navigationTitle("Playback & Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
