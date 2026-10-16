import SwiftUI

struct MacAddLinkView: View {
    @Environment(\.dismiss) private var dismiss
    let model: MacAppModel
    @State private var link = ""
    @State private var isAdding = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add to Queue")
                .font(.title2.bold())
            Text("Paste a podcast episode, YouTube, X, or Instagram video link.")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { add() }
                .accessibilityLabel("Link")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isAdding ? "Adding…" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdding || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { isFocused = true }
    }

    private func add() {
        guard !isAdding else { return }
        isAdding = true
        Task {
            if await model.addLink(link) {
                dismiss()
            }
            isAdding = false
        }
    }
}
