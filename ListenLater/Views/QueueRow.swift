import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            QueueThumbnail(item: item, nowPlaying: nowPlaying)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.isInPlayedSection ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Label(item.sourceName, systemImage: item.source.symbolName)
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .opacity(item.isInPlayedSection ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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
            .lineLimit(2)
        case .ready:
            if isCurrent {
                Text(nowPlayingStatus)
                    .foregroundStyle(.tint)
            } else if item.isInPlayedSection {
                Label("Played", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if item.source == .youtube, item.duration > 0 {
                Text(item.duration.queueCompactDuration)
                    .foregroundStyle(.secondary)
            } else if item.hasMeaningfulProgress {
                Text("\(item.playbackPosition.queueTimestamp) \(progressVerb) · \(item.remainingDuration.queueCompactDuration) left")
                    .foregroundStyle(.secondary)
            } else if item.duration > 0 {
                Text(item.duration.queueCompactDuration)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nowPlaying: QueueThumbnail.NowPlaying? {
        guard isCurrent else { return nil }
        return isPlaying ? .playing : .paused
    }

    private var progressVerb: String {
        item.source.isVideo ? "watched" : "listened"
    }

    private var nowPlayingStatus: String {
        let state = isPlaying ? "Now playing" : "Paused"
        guard item.source != .youtube, item.remainingDuration > 0 else {
            return state
        }
        return "\(state) · \(item.remainingDuration.queueCompactDuration) left"
    }

    private var accessibilityLabel: String {
        var components = [item.title, item.subtitle, item.sourceName]
        if isCurrent {
            components.append(isPlaying ? "Now playing" : "Paused")
        }
        if item.isInPlayedSection {
            components.append("Played")
        }
        if item.status == .unavailable {
            components.append("Unavailable")
        }
        return components.filter { !$0.isEmpty }.joined(separator: ", ")
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
