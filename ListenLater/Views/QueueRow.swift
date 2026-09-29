import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool

    @AppStorage(PlaybackPreferences.videosWaitForScreenKey)
    private var videosWaitForScreen = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the artwork sits above the text so
        // titles get the full width instead of a narrow column.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            QueueThumbnail(item: item, nowPlaying: nowPlaying)
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .opacity(item.isInPlayedSection ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.isInPlayedSection ? .secondary : .primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.sourceName, systemImage: item.source.symbolName)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Label(item.sourceName, systemImage: item.source.symbolName)
                        if !item.subtitle.isEmpty {
                            Text("·")
                            Text(item.subtitle)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            statusLine
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.status {
        case .resolving:
            Label("Fetching details…", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .unavailable:
            Label(
                item.unavailableReason ?? "Unavailable",
                systemImage: "exclamationmark.circle"
            )
            .foregroundStyle(.red)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        case .ready:
            if isCurrent {
                Text(nowPlayingStatus)
                    .foregroundStyle(.tint)
            } else if item.isInPlayedSection {
                Label("Played", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if item.hasMeaningfulProgress, item.source != .youtube {
                Text(progressStatus)
                    .foregroundStyle(.secondary)
            } else if needsScreen {
                // YouTube can't play hidden, and other videos wait while the
                // phone is locked, so say so before the queue reaches them.
                Label(needsScreenStatus, systemImage: "iphone")
                    .foregroundStyle(.secondary)
            } else if item.duration > 0 {
                Text(item.duration.queueCompactDuration)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The same status the row shows, as words for VoiceOver.
    private var statusDescription: String? {
        switch item.status {
        case .resolving:
            return "Fetching details"
        case .unavailable:
            return item.unavailableReason ?? "Unavailable"
        case .ready:
            if isCurrent {
                return nowPlayingStatus
            }
            if item.isInPlayedSection {
                return "Played"
            }
            if item.hasMeaningfulProgress, item.source != .youtube {
                return progressStatus
            }
            if needsScreen {
                return needsScreenStatus
            }
            return item.duration > 0 ? item.duration.queueCompactDuration : nil
        }
    }

    private var nowPlaying: QueueThumbnail.NowPlaying? {
        guard isCurrent else { return nil }
        return isPlaying ? .playing : .paused
    }

    private var needsScreen: Bool {
        item.source == .youtube || (item.source.isVideo && videosWaitForScreen)
    }

    private var needsScreenStatus: String {
        guard item.duration > 0 else { return "Needs screen" }
        return "\(item.duration.queueCompactDuration) · Needs screen"
    }

    private var progressStatus: String {
        let verb = item.source.isVideo ? "watched" : "listened"
        return "\(item.playbackPosition.queueTimestamp) \(verb) · \(item.remainingDuration.queueCompactDuration) left"
    }

    private var nowPlayingStatus: String {
        let state = isPlaying ? "Now playing" : "Paused"
        guard item.source != .youtube, item.remainingDuration > 0 else {
            return state
        }
        return "\(state) · \(item.remainingDuration.queueCompactDuration) left"
    }

    private var accessibilityLabel: String {
        [item.title, item.subtitle, item.sourceName, statusDescription ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if item.status == .unavailable {
            return "Shows why it can’t play and what you can do."
        }
        if isCurrent {
            return isPlaying ? "Pauses playback." : "Resumes playback."
        }
        return "Plays it now."
    }
}

/// The square media slot every queue row uses, so titles line up whatever
/// the source. Video frames are cropped to fill it.
struct QueueThumbnail: View {
    enum NowPlaying {
        case playing
        case paused
    }

    let item: QueueItem
    var nowPlaying: NowPlaying?
    var size: CGFloat = 60

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
        ZStack {
            ArtworkPlaceholder(source: item.source, symbolSize: size * 0.34)

            if let artworkURL = item.artworkURL {
                AsyncImage(url: artworkURL, transaction: Transaction(animation: .easeInOut)) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
            } else if item.source == .socialVideo {
                GeneratedVideoThumbnail(
                    videoURL: item.playbackURL,
                    cacheKey: item.canonicalURL ?? item.originalURL,
                    maximumSize: CGSize(width: size * 3, height: size * 3)
                )
            }

            if let nowPlaying {
                Color.black.opacity(0.45)
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: nowPlaying == .playing
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if item.source.isVideo, nowPlaying == nil {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.07)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(size * 0.06)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The gradient shown until artwork loads, or when there is none.
struct ArtworkPlaceholder: View {
    let source: MediaSource
    let symbolSize: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: source.symbolName)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
        }
    }

    private var colors: [Color] {
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
                    .overlay {
                        if url != nil {
                            ProgressView().controlSize(.small)
                        }
                    }
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
        ArtworkPlaceholder(source: source, symbolSize: size * 0.34)
    }
}

/// A frame grabbed from a social video that has no thumbnail URL.
private struct GeneratedVideoThumbnail: View {
    let videoURL: URL?
    let cacheKey: URL?
    let maximumSize: CGSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: videoURL) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        guard let key = cacheKey ?? videoURL else {
            image = nil
            return
        }
        let thumbnail = await VideoThumbnailCache.shared.thumbnail(
            for: videoURL,
            cacheKey: key,
            maximumSize: maximumSize
        )
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut) {
            image = thumbnail
        }
    }
}

/// Frames grabbed from social videos, kept in memory and on disk. The media
/// URLs expire within minutes, so a frame that isn't kept can't be fetched
/// again after a relaunch.
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()

    private let images = NSCache<NSURL, UIImage>()
    private var failedVideoURLs: Set<URL> = []
    private let directory: URL?

    private init() {
        images.countLimit = 100
        directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VideoThumbnails", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func thumbnail(
        for videoURL: URL?,
        cacheKey: URL,
        maximumSize: CGSize
    ) async -> UIImage? {
        if let cached = images.object(forKey: cacheKey as NSURL) {
            return cached
        }
        let file = fileURL(for: cacheKey)
        if let file,
           let data = try? Data(contentsOf: file),
           let stored = UIImage(data: data)
        {
            images.setObject(stored, forKey: cacheKey as NSURL)
            return stored
        }

        // A URL that failed once has usually expired; don't retry it on
        // every scroll. A refreshed URL is a new key and gets a new attempt.
        guard let videoURL, !failedVideoURLs.contains(videoURL) else {
            return nil
        }

        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize

        do {
            let result = try await generator.image(
                at: CMTime(seconds: 0.1, preferredTimescale: 600)
            )
            let thumbnail = UIImage(cgImage: result.image)
            images.setObject(thumbnail, forKey: cacheKey as NSURL)
            if let file, let data = thumbnail.jpegData(compressionQuality: 0.8) {
                try? data.write(to: file, options: .atomic)
            }
            return thumbnail
        } catch {
            failedVideoURLs.insert(videoURL)
            return nil
        }
    }

    private func fileURL(for key: URL) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }
}
