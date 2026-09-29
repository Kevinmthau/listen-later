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
        // Spotify's own site, player and share links. Other spotify.com
        // hosts, such as podcasters.spotify.com episode pages, belong to RSS
        // shows and are searched like any web page.
        if ["spotify.com", "www.spotify.com"].contains(host)
            || host.matchesDomain(in: [
                "open.spotify.com", "play.spotify.com", "spotify.link", "spotify.app.link", "spoti.fi",
            ])
        {
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
    /// found. Within text, an explicit https:// link wins, then an http://
    /// one (so the classifier can say why it's refused), then a bare domain:
    /// shared text often names a site ("Via NPR.org") before the real link.
    /// Returns nil when the text holds no web link.
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
        var explicitHTTPS: URL?
        var bareDomain: URL?
        var explicitHTTP: URL?
        for match in detector.matches(in: trimmed, options: [], range: range) {
            guard let url = match.url,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let matchRange = Range(match.range, in: trimmed)
            else {
                continue
            }
            let matched = String(trimmed[matchRange])
            let lowercased = matched.lowercased()
            if lowercased.hasPrefix("https://") {
                explicitHTTPS = explicitHTTPS ?? url
            } else if lowercased.hasPrefix("http://") {
                explicitHTTP = explicitHTTP ?? url
            } else if !matched.contains("://"),
                      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            {
                // The detector gives a bare domain http://; upgrade it, as
                // for a bare link above.
                components.scheme = "https"
                bareDomain = bareDomain ?? components.url
            }
        }
        return explicitHTTPS ?? explicitHTTP ?? bareDomain
    }
}

private extension String {
    func matchesDomain(in domains: [String]) -> Bool {
        domains.contains { self == $0 || hasSuffix(".\($0)") }
    }
}
