import SwiftUI

struct NowPlayingCard: View {
    let playback: PlaybackCoordinator
    let queue: QueueStore
    let isCompact: Bool
    let onExpand: () -> Void
    let onMinimize: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: isCompact ? 9 : 13) {
            nowPlayingHeader

            if let item = playback.currentItem {
                currentContent(item)
            } else {
                idleContent
            }
        }
        .padding(isCompact ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        )
        .onChange(of: playback.position) { _, newValue in
            if !isScrubbing {
                scrubPosition = newValue
            }
        }
        .onChange(of: playback.currentItemID) { _, _ in
            scrubPosition = playback.position
        }
        .onAppear {
            scrubPosition = playback.position
        }
    }

    private var nowPlayingHeader: some View {
        HStack(spacing: 8) {
            if isCompact, let item = playback.currentItem {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
            } else {
                Text("NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let item = playback.currentItem {
                if !isCompact {
                    Label(item.source.displayName, systemImage: item.source.symbolName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if isCompact,
                   item.source.isVideo,
                   playback.transportState != .requiresYouTubeApp {
                    Button {
                        playback.playOrPause()
                    } label: {
                        Image(
                            systemName: playback.transportState.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(
                        playback.transportState.isPlaying ? "Pause" : "Play"
                    )
                    .accessibilityIdentifier("play-pause-button")
                }

                if let shareURL = item.videoShareURL {
                    ShareLink(
                        item: shareURL,
                        subject: Text(item.title)
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            playback.youtubePlayerWillBeCovered()
                        }
                    )
                    .accessibilityLabel("Share video")
                    .accessibilityIdentifier("share-current-video-button")
                }

                if isCompact {
                    Button(action: onExpand) {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Expand player")
                    .accessibilityIdentifier("expand-player-button")
                } else if item.source.isVideo {
                    Button(action: onMinimize) {
                        Image(systemName: "chevron.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Minimize player")
                    .accessibilityIdentifier("minimize-player-button")
                }
            }
        }
    }

    @ViewBuilder
    private func currentContent(_ item: QueueItem) -> some View {
        switch item.source {
        case .podcast:
            podcastIdentity(item)
        case .socialVideo:
            socialVideoSurface
        case .youtube:
            youtubeSurface(item)
        }

        if !isCompact {
            VStack(spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if playback.transportState == .requiresYouTubeApp {
                openInYouTubeButton(for: item)
            } else {
                progressControls(for: item)
                transportControls
            }

            if let notice = playback.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if playback.transportState == .requiresYouTubeApp {
            openInYouTubeButton(for: item)
        }
    }

    private func openInYouTubeButton(for item: QueueItem) -> some View {
        Button {
            if let url = item.originalURL {
                openURL(url)
            }
        } label: {
            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private var socialVideoSurface: some View {
        NativeVideoPlayerView(player: playback.nativeVideoPlayer)
            .frame(minWidth: 200)
            .frame(height: isCompact ? 112 : 225)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHint(
                isCompact
                    ? "Use the play control above or expand the player"
                    : "Use the playback controls below to watch"
            )
    }

    private func youtubeSurface(_ item: QueueItem) -> some View {
        Group {
            if item.youtubeMadeForKids {
                ArtworkView(url: item.artworkURL, source: .youtube, size: 112)
                    .padding(.vertical, 4)
            } else {
                YouTubePlayerView(model: playback.youtubePlayer)
                    .frame(minWidth: 200)
                    .frame(height: isCompact ? 200 : 225)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHint("Official YouTube embedded player")
            }
        }
    }

    private func podcastIdentity(_ item: QueueItem) -> some View {
        HStack(spacing: 14) {
            ArtworkView(url: item.artworkURL, source: item.source, size: 82)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.hasMeaningfulProgress ? "RESUME" : "UP NEXT")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.tint)
                Text(item.duration > 0 ? item.remainingDuration.queueCompactDuration + " remaining" : "Ready to play")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func progressControls(for item: QueueItem) -> some View {
        VStack(spacing: 3) {
            Slider(
                value: $scrubPosition,
                in: 0...max(1, playback.duration),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        playback.seek(to: scrubPosition)
                    }
                }
            )
            .accessibilityLabel("Playback position")

            HStack {
                Text((isScrubbing ? scrubPosition : playback.position).queueTimestamp)
                Spacer()
                if item.source == .youtube {
                    Text(playback.duration.queueTimestamp)
                } else {
                    Text("-\(max(0, playback.duration - (isScrubbing ? scrubPosition : playback.position)).queueTimestamp)")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 30) {
            Button {
                playback.skipBack()
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                playback.playOrPause()
            } label: {
                Image(
                    systemName: playback.transportState.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.title2)
                .foregroundStyle(Palette.onAccent)
                .frame(width: 58, height: 58)
                .background(.tint, in: Circle())
            }
            .accessibilityLabel(
                playback.transportState.isPlaying ? "Pause" : "Play"
            )
            .accessibilityIdentifier("play-pause-button")

            Button {
                playback.skipForward()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip forward 30 seconds")

            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                    Button {
                        playback.setPlaybackRate(rate)
                    } label: {
                        if playback.playbackRate == rate {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(rateLabel(playback.playbackRate))
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 36)
            }
            .accessibilityLabel("Playback speed")
        }
        .buttonStyle(.plain)
    }

    private var idleContent: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.25, blue: 0.33),
                                .indigo.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 5) {
                Text(queue.firstUnplayed() == nil ? "Nothing waiting" : "Ready when you are")
                    .font(.headline)
                Text(
                    queue.firstUnplayed() == nil
                        ? "Share something worth hearing."
                        : "Press Play. The queue handles the rest."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button {
                playback.playOrPause()
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 52, height: 52)
                    .background(.tint, in: Circle())
            }
            .disabled(queue.firstUnplayed() == nil)
            .accessibilityLabel("Play queue")
            .accessibilityIdentifier("play-queue-button")
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == floor(rate) ? "\(Int(rate))×" : "\(rate.formatted())×"
    }
}
