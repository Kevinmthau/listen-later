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

extension ProviderResolutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "The URL is not a supported secure public HTTPS URL: \(url.absoluteString)"
        case let .unsupportedURL(url):
            "No provider recognizes \(url.absoluteString)."
        case .missingYouTubeAPIKey:
            "The YouTube Data API key is not configured."
        case let .invalidYouTubeVideoURL(url):
            "The URL does not contain a valid YouTube video ID: \(url.absoluteString)"
        case let .invalidSocialVideoURL(url):
            "The URL is not a supported public X or Instagram video post: \(url.absoluteString)"
        case .videoGrabberUnauthorized:
            "The video resolver rejected its API token. Check the app’s video-grabber configuration."
        case let .itemUnavailable(reason):
            "The item is unavailable. \(reason)"
        case let .youtubeVideoNotEmbeddable(videoID):
            "YouTube video \(videoID) does not permit embedded playback."
        case let .invalidHTTPResponse(url):
            "The server returned an invalid response for \(url.absoluteString)."
        case let .httpStatus(status, url):
            "The server returned HTTP \(status) for \(url.absoluteString)."
        case let .responseTooLarge(url, maximumBytes):
            "The response from \(url.absoluteString) exceeded \(maximumBytes) bytes."
        case let .malformedResponse(message):
            "The provider returned malformed data. \(message)"
        case let .rssFeedNotFound(url):
            "No podcast RSS feed was advertised by \(url.absoluteString)."
        case let .podcastEpisodeNotFound(url):
            "No matching podcast episode was found for \(url.absoluteString)."
        case let .podcastAudioEnclosureMissing(url):
            "The matching podcast episode has no playable audio enclosure: \(url.absoluteString)."
        case let .network(message):
            "The request failed. \(message)"
        }
    }
}
