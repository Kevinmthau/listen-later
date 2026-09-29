import Foundation

struct DirectPodcastAudioResolver: Sendable {
    static func isLikelyAudioURL(_ url: URL) -> Bool {
        LinkClassifier.isLikelyAudioURL(url)
    }

    static func isAudioMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return mimeType.hasPrefix("audio/")
            || mimeType == "application/ogg"
            || mimeType == "video/mp4"
    }

    func resolve(
        originalURL: URL,
        audioURL: URL? = nil,
        canonicalURL: URL? = nil,
        title: String? = nil,
        creatorName: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil
    ) throws -> ProviderResolvedItem {
        let audioURL = audioURL ?? originalURL
        guard ProviderURLSupport.isHTTPURL(audioURL) else {
            throw ProviderResolutionError.invalidURL(audioURL)
        }

        return ProviderResolvedItem(
            originalURL: originalURL,
            canonicalURL: canonicalURL ?? originalURL,
            title: ProviderTextSupport.cleanedTitle(title)
                ?? ProviderURLSupport.inferredTitle(from: audioURL),
            creatorName: ProviderTextSupport.cleanedTitle(creatorName)
                ?? audioURL.host,
            artworkURL: artworkURL,
            duration: duration,
            publishedAt: publishedAt,
            source: .podcast,
            playback: .remoteAudio(audioURL),
            isMadeForKids: false
        )
    }
}

struct RSSMatchHints: Hashable, Sendable {
    let originalURL: URL
    let canonicalURL: URL?
    let episodeTitle: String?
    let episodeID: String?
    let directAudioURL: URL?

    init(
        originalURL: URL,
        canonicalURL: URL? = nil,
        episodeTitle: String? = nil,
        episodeID: String? = nil,
        directAudioURL: URL? = nil
    ) {
        self.originalURL = originalURL
        self.canonicalURL = canonicalURL
        self.episodeTitle = episodeTitle
        self.episodeID = episodeID
        self.directAudioURL = directAudioURL
    }
}

struct RSSMatcher: Sendable {
    func bestMatch(in feed: RSSFeed, hints: RSSMatchHints) -> RSSEpisode? {
        let playableEpisodes = feed.episodes.filter { $0.audioURL != nil }

        let scored = playableEpisodes.enumerated().map { index, episode in
            (
                episode: episode,
                score: score(episode, hints: hints),
                index: index
            )
        }

        guard let best = scored.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index > rhs.index
            }
            return lhs.score < rhs.score
        }),
        best.score >= 250
        else {
            return nil
        }

        return best.episode
    }

    func resolvedItem(
        from episode: RSSEpisode,
        feed: RSSFeed,
        hints: RSSMatchHints
    ) throws -> ProviderResolvedItem {
        guard let audioURL = episode.audioURL else {
            throw ProviderResolutionError.podcastAudioEnclosureMissing(
                episode.linkURL ?? hints.originalURL
            )
        }

        return try DirectPodcastAudioResolver().resolve(
            originalURL: hints.originalURL,
            audioURL: audioURL,
            canonicalURL: episode.linkURL ?? hints.canonicalURL ?? hints.originalURL,
            title: episode.title ?? hints.episodeTitle,
            creatorName: episode.author ?? feed.author ?? feed.title,
            artworkURL: episode.artworkURL ?? feed.artworkURL,
            duration: episode.duration,
            publishedAt: episode.publishedAt
        )
    }

    private func score(_ episode: RSSEpisode, hints: RSSMatchHints) -> Int {
        var score = 0

        if ProviderURLSupport.sameResource(episode.audioURL, hints.directAudioURL) {
            score += 1_200
        }

        for pageURL in [hints.originalURL, hints.canonicalURL].compactMap({ $0 }) {
            if ProviderURLSupport.sameResource(episode.linkURL, pageURL) {
                score += 1_000
            } else if ProviderURLSupport.sameHostAndPath(episode.linkURL, pageURL) {
                score += 800
            }

            if let guidURL = episode.guid.flatMap(URL.init(string:)),
               ProviderURLSupport.sameResource(guidURL, pageURL)
            {
                score += 900
            } else if episode.guid == pageURL.absoluteString {
                score += 850
            }
        }

        if let episodeID = hints.episodeID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !episodeID.isEmpty
        {
            if episode.guid?.localizedCaseInsensitiveContains(episodeID) == true {
                score += 750
            }
            if episode.linkURL?.absoluteString
                .localizedCaseInsensitiveContains(episodeID) == true
            {
                score += 650
            }
        }

        let hintTitle = ProviderTextSupport.normalizedTitle(hints.episodeTitle)
        let episodeTitle = ProviderTextSupport.normalizedTitle(episode.title)
        if !hintTitle.isEmpty, !episodeTitle.isEmpty {
            if hintTitle == episodeTitle {
                score += 800
            } else if hintTitle.contains(episodeTitle)
                        || episodeTitle.contains(hintTitle)
            {
                score += 550
            } else {
                let similarity = tokenSimilarity(hintTitle, episodeTitle)
                if similarity >= 0.75 {
                    score += 450
                } else if similarity >= 0.6 {
                    score += 300
                }
            }
        }

        let slug = hints.originalURL.deletingPathExtension().lastPathComponent
        let normalizedSlug = ProviderTextSupport.normalizedTitle(
            slug.replacingOccurrences(of: "-", with: " ")
        )
        if normalizedSlug.count >= 6, !episodeTitle.isEmpty {
            let similarity = tokenSimilarity(normalizedSlug, episodeTitle)
            if similarity >= 0.75 {
                score += 300
            } else if similarity >= 0.6 {
                score += 200
            }
        }

        return score
    }

    private func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let leftTokens = Set(lhs.split(separator: " ").map(String.init))
        let rightTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }

        let intersection = leftTokens.intersection(rightTokens).count
        let smallerCount = min(leftTokens.count, rightTokens.count)
        return Double(intersection) / Double(smallerCount)
    }
}
