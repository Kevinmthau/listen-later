import SwiftUI

struct AddURLView: View {
    let add: (URL) async -> QueueItem?

    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var isAdding = false
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $urlString, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Podcast, X video, Instagram video, or YouTube URL")
                } header: {
                    Text("Podcast or Video URL")
                } footer: {
                    Text("Paste a podcast, X, Instagram, or YouTube link. The Share Sheet is usually faster.")
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
                    Button {
                        submit()
                    } label: {
                        if isAdding {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(isAdding || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https"
        else {
            validationMessage = "Enter a complete secure HTTPS URL."
            return
        }

        isAdding = true
        validationMessage = nil
        Task {
            let item = await add(url)
            isAdding = false
            if item == nil {
                validationMessage = "This link couldn’t be added."
            } else {
                dismiss()
            }
        }
    }
}

struct PlaybackInfoView: View {
    let isCloudBacked: Bool
    let persistenceNotice: String?
    let youtubeIsConfigured: Bool
    let videoGrabberIsConfigured: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
