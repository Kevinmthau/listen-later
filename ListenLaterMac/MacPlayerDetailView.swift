import AppKit
import AVKit
import SwiftUI

struct MacPlayerDetailView: View {
    let model: MacAppModel
    let item: QueueItem?
    @State private var posterImage: NSImage?

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        mediaSurface(for: item)
                        titleBlock(for: item)
                        statusBlock(for: item)
                        controls(for: item)
                    }
                    .frame(maxWidth: 820)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }
                .task(id: item.id) {
                    posterImage = nil
                    if let url = await model.localPosterURL(for: item) {
                        posterImage = NSImage(contentsOf: url)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Choose Something to Play",
                    systemImage: "play.rectangle",
                    description: Text("Select an item from the queue.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func mediaSurface(for item: QueueItem) -> some View {
        let isCurrent = model.playback.currentItemID == item.id
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black)
            if isCurrent,
               item.source != .youtube,
               let player = model.playback.nativePlayer {
                MacNativePlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let posterImage {
                Image(nsImage: posterImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let artworkURL = item.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        placeholder(for: item)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                placeholder(for: item)
            }
        }
        .aspectRatio(aspectRatio(for: item), contentMode: .fit)
        .frame(maxHeight: 430)
        .accessibilityLabel("Media player for \(item.title)")
    }

    private func placeholder(for item: QueueItem) -> some View {
        ZStack {
            LinearGradient(
                colors: [.brown.opacity(0.85), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: item.source.symbolName)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func titleBlock(for item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Label(item.sourceName, systemImage: item.source.symbolName)
                if !item.subtitle.isEmpty {
                    Text("·")
                    Text(item.subtitle)
                }
                if item.duration > 0 {
                    Text("·")
                    Text(item.duration.queueCompactDuration)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusBlock(for item: QueueItem) -> some View {
        if item.source == .localVideo,
           model.localAvailability[item.id] == false {
            Label(
                "Not available on this Mac. Automatic playback skips it without changing its saved status.",
                systemImage: "externaldrive.badge.xmark"
            )
            .foregroundStyle(.orange)
        }
        if model.playback.currentItemID == item.id,
           let notice = model.playback.notice {
            Label(notice, systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        if item.source == .youtube {
            Text("YouTube metadata comes from oEmbed on Mac. Playback opens in the official YouTube app or website.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func controls(for item: QueueItem) -> some View {
        VStack(spacing: 16) {
            if model.playback.currentItemID == item.id,
               model.playback.duration > 0,
               item.source != .youtube {
                HStack {
                    Text(model.playback.position.playbackClock)
                        .monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { model.playback.position },
                            set: { model.playback.seek(to: $0) }
                        ),
                        in: 0...max(model.playback.duration, 1)
                    )
                    Text(model.playback.duration.playbackClock)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                if item.source == .youtube {
                    Button {
                        model.playback.openYouTube(item)
                    } label: {
                        Label("Open in YouTube", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task {
                            if model.playback.currentItemID != item.id {
                                await model.playback.select(item)
                            }
                            await model.playback.playOrPause()
                        }
                    } label: {
                        Label(
                            model.playback.currentItemID == item.id
                                && model.playback.state == .playing ? "Pause" : "Play",
                            systemImage: model.playback.currentItemID == item.id
                                && model.playback.state == .playing ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(item.source == .localVideo && model.localAvailability[item.id] == false)
                }

                Button {
                    Task { await model.playback.playNext() }
                } label: {
                    Label("Next", systemImage: "forward.end.fill")
                }

                Menu("Speed: \(model.playback.playbackRate.formatted())×") {
                    ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                        Button("\(rate.formatted())×") {
                            model.playback.setPlaybackRate(rate)
                        }
                    }
                }
                .disabled(item.source == .youtube)

                Spacer()
                if item.source != .localVideo && item.source != .unknown {
                    Button("Open Original Link") { model.openOriginal(item) }
                }
            }
        }
    }

    private func aspectRatio(for item: QueueItem) -> CGFloat {
        if item.localPixelWidth > 0, item.localPixelHeight > 0 {
            return item.localPixelWidth / item.localPixelHeight
        }
        return item.source == .podcast ? 1 : 16 / 9
    }
}

private struct MacNativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private extension TimeInterval {
    var playbackClock: String {
        let total = max(0, Int(self.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
