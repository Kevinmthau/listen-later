import Foundation

/// What a shared or pasted link is, decided from the URL alone so the Share
/// Extension can answer instantly without network access.
enum LinkKind: Equatable, Sendable {
    case youtubeVideo
    case socialVideo
    case applePodcastsEpisode
    case audioFile
    /// A web page MushRadio will search for a podcast feed and episode.
    case webPage
    /// A link MushRadio can't play, with the reason to show.
    case unsupported(String)
}

enum LinkClassifier {
    static let audioFileExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "m4b", "mp3",
        "mp4", "oga", "ogg", "opus", "wav"
    ]

    static func classify(_ url: URL) -> LinkKind {
        guard ProviderURLSupport.isHTTPURL(url) else {
            return .unsupported("MushRadio only supports public https:// links.")
        }
        let host = url.host.map(ProviderURLSupport.normalizedHost) ?? ""

        if YouTubeURLParser.isYouTubeURL(url) {
            return YouTubeURLParser.videoID(from: url) == nil
                ? .unsupported("This YouTube link doesn’t point to a video.")
                : .youtubeVideo
        }
        if SocialVideoURLParser.isSupported(url) {
            return .socialVideo
        }
        if host.matchesDomain(in: ["x.com", "twitter.com", "instagram.com", "instagr.am"]) {
            return .unsupported("Only X and Instagram posts with a video can be added.")
        }
        if let link = ApplePodcastsLink.parse(url) {
            return link.episodeID == nil
                ? .unsupported("This Apple Podcasts link is for a show. Share a single episode instead.")
                : .applePodcastsEpisode
        }
        if isLikelyAudioURL(url) {
            return .audioFile
        }
        if host.matchesDomain(in: ["spotify.com", "spotify.link", "spoti.fi"]) {
            return .unsupported(
                "Spotify episodes can only play in Spotify. Share the episode from Apple Podcasts or the show’s website instead."
            )
        }
        if host.matchesDomain(in: ["tiktok.com"]) {
            return .unsupported("TikTok videos aren’t supported yet.")
        }
        if host.matchesDomain(in: ["music.apple.com"]) {
            return .unsupported("Apple Music links aren’t supported.")
        }
        return .webPage
    }

    static func isLikelyAudioURL(_ url: URL) -> Bool {
        audioFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Turns typed, pasted or shared text into a link: a bare
    /// "example.com/episode" gets https://, and a link inside a sentence is
    /// found. Returns nil when the text holds no web link.
    static func link(fromUserText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains(where: \.isWhitespace) {
            if let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http",
               url.host != nil
            {
                return url
            }
            if !trimmed.contains("://"),
               trimmed.contains("."),
               let url = URL(string: "https://\(trimmed)"),
               url.host != nil
            {
                return url
            }
        }

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return detector
            .matches(in: trimmed, options: [], range: range)
            .compactMap(\.url)
            .first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
    }
}

private extension String {
    func matchesDomain(in domains: [String]) -> Bool {
        domains.contains { self == $0 || hasSuffix(".\($0)") }
    }
}
