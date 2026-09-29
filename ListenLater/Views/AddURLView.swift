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
                    .tint(Palette.walnut)
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
