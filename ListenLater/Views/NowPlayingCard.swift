import SwiftUI

struct NowPlayingCard: View {
    static let playbackRates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let sleepTimerMinutes = [5, 15, 30, 45, 60]

    let playback: PlaybackCoordinator
    let queue: QueueStore
    let isCompact: Bool
    let onExpand: () -> Void
    /// Nil where there's room for the full card, e.g. iPad's side column.
    let onMinimize: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var videoAspectRatio: CGFloat = 16.0 / 9.0

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
        // The same flat surface as the queue's sections below it.
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .onChange(of: playback.position) { _, newValue in
            if !isScrubbing {
                scrubPosition = newValue
            }
        }
        .onChange(of: playback.currentItemID) { _, _ in
            scrubPosition = playback.position
            videoAspectRatio = 16.0 / 9.0
            // The full-screen player shows the shared AVPlayer. Close it when
            // the queue moves to audio or YouTube, which it can't show; a
            // YouTube video would otherwise start underneath it.
            if playback.currentItem?.source != .socialVideo {
                FullScreenVideo.dismiss()
            }
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

        if playback.activity == .playsInYouTubeApp {
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

            // The route sheet would cover the YouTube player while it plays,
            // which the app avoids everywhere else.
            if item.source != .youtube {
                RoutePickerButton(prioritizesVideoDevices: item.source.isVideo)
                    .frame(width: 44, height: 44)
            }

            if let shareURL = item.videoShareURL {
                shareButton(for: shareURL, title: item.title)
            }

            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Minimize player")
                .accessibilityIdentifier("minimize-player-button")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
            .accessibilityValue(positionDescription)
            // Swiping up or down skips like the buttons, instead of moving
            // the slider by a percentage.
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    playback.skipForward()
                case .decrement:
                    playback.skipBack()
                @unknown default:
                    break
                }
            }

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
            .accessibilityValue(playback.activity.isWaitingForMedia ? "Loading" : "")
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
        // Glyphs past this size overflow their 44 pt slots without being
        // easier to use; VoiceOver labels carry the meaning.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var positionDescription: String {
        let elapsed = spokenDuration(isScrubbing ? scrubPosition : playback.position)
        guard playback.duration > 0 else { return elapsed }
        return "\(elapsed) of \(spokenDuration(playback.duration))"
    }

    private func spokenDuration(_ seconds: TimeInterval) -> String {
        let whole = seconds.isFinite ? max(0, seconds.rounded()) : 0
        return Duration.seconds(whole).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide)
        )
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

            if playback.activity != .playsInYouTubeApp {
                Button {
                    playback.playOrPause()
                } label: {
                    playPauseGlyph(spinnerTint: nil)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(playPauseAccessibilityLabel)
                .accessibilityValue(playback.activity.isWaitingForMedia ? "Loading" : "")
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

        if playback.activity == .playsInYouTubeApp {
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
        // At accessibility text sizes the message gets the full width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 15))
        return VStack(alignment: .leading, spacing: 12) {
            layout {
                WaveformTile()

                VStack(alignment: .leading, spacing: 5) {
                    Text(hasUnplayed ? "Ready when you are" : "All caught up")
                        .font(.headline)
                    Text(
                        hasUnplayed
                            ? "Press Play. The queue handles the rest."
                            : "Share something worth hearing."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 6)
                }

                // Everything is played: no button, rather than a disabled
                // one that raises the question of how to enable it.
                if hasUnplayed {
                    Button {
                        playback.playOrPause()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 52, height: 52)
                            .background(.tint, in: Circle())
                    }
                    .accessibilityLabel("Play queue")
                    .accessibilityIdentifier("play-queue-button")
                }
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
        if playback.activity.isWaitingForMedia {
            ProgressView()
                .tint(spinnerTint)
        } else {
            Image(
                systemName: playback.activity.pausesOnTap
                    ? "pause.fill"
                    : "play.fill"
            )
        }
    }

    private var playPauseAccessibilityLabel: String {
        playback.activity.pausesOnTap ? "Pause" : "Play"
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

    /// On iPhone a vertical reel at full width would push the controls and
    /// the queue off a small screen, so it gets at most 30% of the screen's
    /// height. iPad's side column has room for 360 pt.
    private var expandedVideoMaxHeight: CGFloat {
        guard onMinimize != nil else { return 360 }
        return min(360, UIScreen.main.bounds.height * 0.3)
    }

    /// Sized to the video's own shape, so a vertical reel is tall and
    /// narrow rather than a sliver in a wide black box.
    private var socialVideoSurface: some View {
        VideoFrameLayout(
            aspectRatio: videoAspectRatio,
            maxHeight: isCompact ? 112 : expandedVideoMaxHeight
        ) {
            NativeVideoPlayerView(player: playback.nativeVideoPlayer) { size in
                guard size.width > 0, size.height > 0 else { return }
                videoAspectRatio = size.width / size.height
            }
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if !isCompact, let player = playback.nativeVideoPlayer {
                    Button {
                        FullScreenVideo.present(player)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.45), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                    .accessibilityLabel("Watch full screen")
                    .accessibilityIdentifier("full-screen-video-button")
                }
            }
            .accessibilityHint(
                isCompact
                    ? "Use the play control above or expand the player"
                    : "Use the playback controls below to watch"
            )
        }
    }

    private func youtubeSurface(_ item: QueueItem) -> some View {
        Group {
            if item.youtubeMadeForKids {
                ArtworkView(url: item.artworkURL, source: .youtube, size: 112)
                    .padding(.vertical, 4)
            } else {
                // YouTube's terms require at least 200 x 200 pt, and its
                // player letterboxes within the frame itself.
                VideoFrameLayout(
                    aspectRatio: 16.0 / 9.0,
                    maxHeight: isCompact ? 200 : 360,
                    minHeight: 200,
                    fillsWidth: true
                ) {
                    YouTubePlayerView(model: playback.youtubePlayer)
                        .accessibilityHint("Official YouTube embedded player")
                }
                .frame(minWidth: 200)
            }
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == floor(rate) ? "\(Int(rate))×" : "\(rate.formatted())×"
    }
}
