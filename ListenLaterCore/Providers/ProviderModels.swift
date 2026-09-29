import Foundation

enum ProviderSource: String, Codable, CaseIterable, Sendable {
    case podcast
    case socialVideo
    case youtube

    var displayName: String {
        switch self {
        case .podcast:
            "Podcast"
        case .socialVideo:
            "Social Video"
        case .youtube:
            "YouTube"
        }
    }
}

/// Describes how the app may play an item without conflating YouTube videos
/// with directly playable media URLs.
enum ProviderPlaybackReference: Hashable, Codable, Sendable {
    case remoteAudio(URL)
    case remoteVideo(URL, expiresAt: Date)
    case youtubeVideoID(String)

    var remoteAudioURL: URL? {
        guard case let .remoteAudio(url) = self else { return nil }
        return url
    }

    var youtubeVideoID: String? {
        guard case let .youtubeVideoID(videoID) = self else { return nil }
        return videoID
    }

    var remoteVideoURL: URL? {
        guard case let .remoteVideo(url, _) = self else { return nil }
        return url
    }

    var remoteVideoExpiresAt: Date? {
        guard case let .remoteVideo(_, expiresAt) = self else { return nil }
        return expiresAt
    }
}

struct ProviderResolvedItem: Hashable, Codable, Sendable {
    let originalURL: URL
    let canonicalURL: URL
    let title: String
    let creatorName: String?
    let artworkURL: URL?
    let duration: TimeInterval?
    let publishedAt: Date?
    let source: ProviderSource
    let playback: ProviderPlaybackReference
    let isMadeForKids: Bool
}

protocol MediaProvider: Sendable {
    var source: ProviderSource { get }

    func canResolve(_ url: URL) -> Bool
    func resolve(_ url: URL) async throws -> ProviderResolvedItem
}

enum ProviderResolutionError: Error, Equatable, Sendable {
    case invalidURL(URL)
    case unsupportedURL(URL)
    case missingYouTubeAPIKey
    case invalidYouTubeVideoURL(URL)
    case invalidSocialVideoURL(URL)
    case videoGrabberUnauthorized
    case itemUnavailable(String)
    case youtubeVideoNotEmbeddable(String)
    case invalidHTTPResponse(URL)
    case httpStatus(Int, URL)
    case responseTooLarge(URL, maximumBytes: Int)
    case malformedResponse(String)
    case rssFeedNotFound(URL)
    case podcastEpisodeNotFound(URL)
    case podcastAudioEnclosureMissing(URL)
    case network(String)
}

/// Messages are shown in the queue, so they say what happened and what to
/// do in plain words rather than repeating URLs or protocol details.
extension ProviderResolutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "MushRadio only supports public https:// links."
        case .unsupportedURL:
            "MushRadio doesn’t support this kind of link."
        case .missingYouTubeAPIKey:
            "YouTube isn’t set up in this build of MushRadio."
        case .invalidYouTubeVideoURL:
            "This YouTube link doesn’t point to a video."
        case .invalidSocialVideoURL:
            "Only X and Instagram posts with a video can be added."
        case .videoGrabberUnauthorized:
            "The video service didn’t accept this app’s access token."
        case let .itemUnavailable(reason):
            reason
        case .youtubeVideoNotEmbeddable:
            "The owner of this video only allows it to play on YouTube."
        case .invalidHTTPResponse:
            "The site sent a response MushRadio couldn’t read. Try again later."
        case let .httpStatus(status, _):
            Self.describe(httpStatus: status)
        case .responseTooLarge:
            "The page was too large for MushRadio to read."
        case .malformedResponse:
            "The service sent data MushRadio couldn’t read. Try again later."
        case .rssFeedNotFound:
            "This page doesn’t link to a podcast feed, so MushRadio can’t find the episode."
        case .podcastEpisodeNotFound:
            "MushRadio couldn’t find this episode in the show’s feed."
        case .podcastAudioEnclosureMissing:
            "This episode doesn’t include audio MushRadio can play."
        case let .network(message):
            message.isEmpty
                ? "Couldn’t connect. Check your connection and try again."
                : message
        }
    }

    private static func describe(httpStatus status: Int) -> String {
        switch status {
        case 401, 403:
            "The site wouldn’t let MushRadio open this link."
        case 404, 410:
            "This page couldn’t be found. It may have been removed."
        case 429:
            "The site is busy. Try again in a moment."
        case 500...599:
            "The site had a problem. Try again later."
        default:
            "The site returned an error (\(status))."
        }
    }
}
