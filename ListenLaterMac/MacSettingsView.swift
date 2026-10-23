import SwiftUI

struct MacSettingsView: View {
    let localMediaRoot: String
    let isCloudBacked: Bool
    let persistenceNotice: String?

    var body: some View {
        Form {
            Section("Queue") {
                LabeledContent("Linked items") {
                    Text(isCloudBacked ? "Private iCloud queue" : "Local fallback")
                }
                Text(isCloudBacked
                    ? "Links added here sync with MushRadio on your iPhone and iPad using the same iCloud account. Sync may take a moment."
                    : "Links are saved on this Mac. Relaunch after fixing the iCloud setup to resume sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let persistenceNotice {
                    Text(persistenceNotice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("Local Videos") {
                LabeledContent("Storage") {
                    Text(localMediaRoot)
                        .textSelection(.enabled)
                }
                Text("Imported movie bytes stay on this Mac. MushRadio copies them into app-owned storage and keeps deleted files in internal Trash for seven days so Undo can restore them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("YouTube") {
                Text("The Mac app uses public oEmbed metadata and opens playback in YouTube. It does not use the iOS-restricted Data API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 520, height: 390)
    }
}
