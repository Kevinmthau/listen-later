import SwiftUI

struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(
                url: item.artworkURL,
                source: item.source,
                size: item.source.isVideo ? 94 : 54
            )
            .overlay(alignment: .bottomTrailing) {
                if isCurrent, item.source == .podcast {
                    Image(systemName: "waveform")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.tint, in: Circle())
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.isPlayed ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Label(item.source.displayName, systemImage: item.source.symbolName)
                    if !item.subtitle.isEmpty {
                        Text("·")
                        Text(item.subtitle)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                statusLine
                    .font(.caption2)
            }

            Spacer(minLength: 4)

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .opacity(item.isPlayed ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.status {
        case .resolving:
            Label("Resolving metadata", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("Unavailable · tap to retry", systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .ready:
            if item.isPlayed {
                Label("Played", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if item.source == .youtube, item.duration > 0 {
                Text(item.duration.queueCompactDuration)
                    .foregroundStyle(.secondary)
            } else if item.hasMeaningfulProgress {
                Text("\(item.playbackPosition.queueTimestamp) listened · \(item.remainingDuration.queueCompactDuration) left")
                    .foregroundStyle(.secondary)
            } else if item.duration > 0 {
                Text(item.duration.queueCompactDuration)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityLabel: String {
        var components = [item.title, item.subtitle, item.source.displayName]
        if item.isPlayed {
            components.append("Played")
        }
        if item.status == .unavailable {
            components.append("Unavailable")
        }
        return components.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct ArtworkView: View {
    let url: URL?
    let source: MediaSource
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: source.isVideo ? .fit : .fill)
            case .empty:
                placeholder
                    .overlay { ProgressView().controlSize(.small) }
            case .failure:
                placeholder
            @unknown default:
                placeholder
            }
        }
        .frame(width: artworkWidth, height: artworkHeight)
        .background(source.isVideo ? Color.black : Color.clear)
        .clipShape(
            RoundedRectangle(
                cornerRadius: source.isVideo ? 4 : size * 0.2,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: source.isVideo ? 4 : size * 0.2,
                style: .continuous
            )
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var artworkWidth: CGFloat {
        source.isVideo ? size * 1.35 : size
    }

    private var artworkHeight: CGFloat {
        source.isVideo ? size * 0.76 : size
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: placeholderColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: source.symbolName)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
        }
    }

    private var placeholderColors: [Color] {
        switch source {
        case .podcast:
            [Color(red: 0.12, green: 0.25, blue: 0.33), .indigo.opacity(0.75)]
        case .socialVideo:
            [.black, Color(red: 0.08, green: 0.42, blue: 0.68)]
        case .youtube:
            [Color(red: 0.45, green: 0.12, blue: 0.12), .red.opacity(0.75)]
        }
    }
}
