import SwiftUI

struct NowPlayingCard: View {
    static let playbackRates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let sleepTimerMinutes = [5, 15, 30, 45, 60]

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
            if let item = playback.currentItem {
                if isCompact {
                    compactContent(item)
                } else {
                    expandedContent(item)
                }
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

    // MARK: - Expanded

    @ViewBuilder
    private func expandedContent(_ item: QueueItem) -> some View {
        expandedHeader(item)

        switch item.source {
        case .podcast:
            HStack(spacing: 14) {
                ArtworkView(url: item.artworkURL, source: item.source, size: 64)
                titleBlock(item)
            }
        case .socialVideo:
            socialVideoSurface
            titleBlock(item)
        case .youtube:
            youtubeSurface(item)
            titleBlock(item)
        }

        if playback.transportState == .requiresYouTubeApp {
            openInYouTubeButton(for: item)
        } else {
            progressControls(for: item)
            transportControls
        }

        noticeLabel
    }

    private func expandedHeader(_ item: QueueItem) -> some View {
        HStack(spacing: 0) {
            Text("NOW PLAYING")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 4)

            sleepTimerMenu

            RoutePickerButton(prioritizesVideoDevices: item.source.isVideo)
                .frame(width: 44, height: 44)

            if let shareURL = item.videoShareURL {
                shareButton(for: shareURL, title: item.title)
            }

            Button(action: onMinimize) {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Minimize player")
            .accessibilityIdentifier("minimize-player-button")
        }
    }

    private func titleBlock(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Five equal slots keep Play centred under the title.
    private var transportControls: some View {
        HStack(spacing: 0) {
            speedMenu
                .frame(maxWidth: .infinity)

            Button {
                playback.skipBack()
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip back 15 seconds")
            .frame(maxWidth: .infinity)

            Button {
                playback.playOrPause()
            } label: {
                playPauseGlyph(spinnerTint: Palette.onAccent)
                    .font(.title2)
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 58, height: 58)
                    .background(.tint, in: Circle())
            }
            .accessibilityLabel(playPauseAccessibilityLabel)
            .accessibilityValue(playback.isWaitingForMedia ? "Loading" : "")
            .accessibilityIdentifier("play-pause-button")
            .frame(maxWidth: .infinity)

            Button {
                playback.skipForward()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Skip forward 30 seconds")
            .frame(maxWidth: .infinity)

            Button {
                playback.playNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .disabled(!playback.hasNextItem)
            .accessibilityLabel("Next item")
            .accessibilityIdentifier("next-item-button")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.playbackRates, id: \.self) { rate in
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
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(rateLabel(playback.playbackRate))
    }

    private var sleepTimerMenu: some View {
        Menu {
            Section("Sleep Timer") {
                ForEach(Self.sleepTimerMinutes, id: \.self) { minutes in
                    Button(sleepTimerTitle(minutes: minutes)) {
                        playback.setSleepTimer(minutes: minutes)
                    }
                }
                Button("End of Item") {
                    playback.setSleepTimerAtEndOfItem()
                }
            }
            if playback.sleepTimer != .off {
                Button("Turn Off Timer", role: .destructive) {
                    playback.cancelSleepTimer()
                }
            }
        } label: {
            sleepTimerLabel
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepTimerAccessibilityValue)
    }

    @ViewBuilder
    private var sleepTimerLabel: some View {
        switch playback.sleepTimer {
        case .off:
            Image(systemName: "moon.zzz")
        case let .until(date):
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                Text(date, style: .timer)
                    .font(.caption.monospacedDigit())
            }
        case .endOfItem:
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                Text("End")
                    .font(.caption)
            }
        }
    }

    private func sleepTimerTitle(minutes: Int) -> String {
        minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }

    private var sleepTimerAccessibilityValue: String {
        switch playback.sleepTimer {
        case .off:
            "Off"
        case let .until(date):
            "Pauses at \(date.formatted(date: .omitted, time: .shortened))"
        case .endOfItem:
            "Pauses at the end of this item"
        }
    }

    private func shareButton(for url: URL, title: String) -> some View {
        ShareLink(item: url, subject: Text(title)) {
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

    // MARK: - Compact

    @ViewBuilder
    private func compactContent(_ item: QueueItem) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if playback.transportState != .requiresYouTubeApp {
                Button {
                    playback.playOrPause()
                } label: {
                    playPauseGlyph(spinnerTint: nil)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(playPauseAccessibilityLabel)
                .accessibilityValue(playback.isWaitingForMedia ? "Loading" : "")
                .accessibilityIdentifier("play-pause-button")
            }

            Button(action: onExpand) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Expand player")
            .accessibilityIdentifier("expand-player-button")
        }

        switch item.source {
        case .podcast:
            EmptyView()
        case .socialVideo:
            socialVideoSurface
        case .youtube:
            youtubeSurface(item)
        }

        if playback.transportState == .requiresYouTubeApp {
            openInYouTubeButton(for: item)
        } else if playback.duration > 0 {
            ProgressView(
                value: min(max(0, playback.position), playback.duration),
                total: playback.duration
            )
            .accessibilityLabel("Playback progress")
        }

        if let notice = playback.notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        let hasUnplayed = queue.firstUnplayed() != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(hasUnplayed ? "Ready when you are" : "Nothing waiting")
                        .font(.headline)
                    Text(
                        hasUnplayed
                            ? "Press Play. The queue handles the rest."
                            : "Share something worth hearing."
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
                .disabled(!hasUnplayed)
                .accessibilityLabel("Play queue")
                .accessibilityIdentifier("play-queue-button")
            }

            noticeLabel
        }
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private var noticeLabel: some View {
        if let notice = playback.notice {
            Label(notice, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func playPauseGlyph(spinnerTint: Color?) -> some View {
        if playback.isWaitingForMedia {
            ProgressView()
                .tint(spinnerTint)
        } else {
            Image(
                systemName: playback.transportState.isPlaying
                    ? "pause.fill"
                    : "play.fill"
            )
        }
    }

    private var playPauseAccessibilityLabel: String {
        playback.transportState.isPlaying ? "Pause" : "Play"
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

    private func rateLabel(_ rate: Double) -> String {
        rate == floor(rate) ? "\(Int(rate))×" : "\(rate.formatted())×"
    }
}
