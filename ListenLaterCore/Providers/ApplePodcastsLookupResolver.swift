import Foundation

struct ApplePodcastsLink: Hashable, Sendable {
    let showID: String
    let episodeID: String?

    static func parse(_ url: URL) -> Self? {
        guard ProviderURLSupport.isHTTPURL(url),
              let rawHost = url.host
        else {
            return nil
        }
        let host = ProviderURLSupport.normalizedHost(rawHost)
        guard
              host == "podcasts.apple.com"
                || host == "itunes.apple.com"
                || host.hasSuffix(".itunes.apple.com")
        else {
            return nil
        }

        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"id(\d+)"#),
              let match = regex.firstMatch(
                  in: path,
                  range: NSRange(path.startIndex..<path.endIndex, in: path)
              ),
              let idRange = Range(match.range(at: 1), in: path)
        else {
            return nil
        }

        let showID = String(path[idRange])
        let episodeID = URLComponents(
            url: url,
            resolvingAgainstBaseURL: true
        )?
        .queryItems?
        .first(where: { $0.name.caseInsensitiveCompare("i") == .orderedSame })?
        .value
        .flatMap { value in
            value.allSatisfy(\.isNumber) ? value : nil
        }

        return Self(showID: showID, episodeID: episodeID)
    }
}

struct ApplePodcastsLookupResolver: Sendable {
    private static let lookupEndpoint = URL(string: "https://itunes.apple.com/lookup")!

    private let client: ProviderHTTPClient
    private let feedParser = RSSFeedParser()
    private let matcher = RSSMatcher()

    init(session: URLSession = .shared) {
        self.client = ProviderHTTPClient(session: session)
    }

    init(client: ProviderHTTPClient) {
        self.client = client
    }

    func canResolve(_ url: URL) -> Bool {
        ApplePodcastsLink.parse(url) != nil
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard let link = ApplePodcastsLink.parse(url) else {
            throw ProviderResolutionError.unsupportedURL(url)
        }
        guard let episodeID = link.episodeID else {
            throw ProviderResolutionError.podcastEpisodeNotFound(url)
        }

        var lookupResult = try await episodeLookup(id: episodeID)

        if lookupResult == nil {
            let showResults = try await lookup(
                id: link.showID,
                entity: "podcastEpisode",
                limit: 200
            )
            lookupResult = showResults.first(where: {
                $0.trackID.map(String.init) == episodeID
            })
        }

        if let lookupResult,
           let audioURL = lookupResult.episodeURL.flatMap(URL.init(string:)),
           ProviderURLSupport.isHTTPURL(audioURL)
        {
            return try DirectPodcastAudioResolver().resolve(
                originalURL: url,
                audioURL: audioURL,
                canonicalURL: lookupResult.trackViewURL.flatMap(URL.init(string:)) ?? url,
                title: lookupResult.trackName,
                creatorName: lookupResult.collectionName ?? lookupResult.artistName,
                artworkURL: lookupResult.bestArtworkURL,
                duration: lookupResult.trackTimeMilliseconds.map { $0 / 1_000 },
                publishedAt: ProviderDateParser.parse(lookupResult.releaseDate)
            )
        }

        let showResults = try await lookup(
            id: link.showID,
            entity: "podcast",
            limit: 1
        )
        let feedURL = lookupResult?.feedURL.flatMap(URL.init(string:))
            ?? showResults.compactMap { $0.feedURL.flatMap(URL.init(string:)) }.first

        guard let feedURL, ProviderURLSupport.isHTTPURL(feedURL) else {
            throw ProviderResolutionError.rssFeedNotFound(url)
        }

        let feed = try await fetchFeed(feedURL)
        let hints = RSSMatchHints(
            originalURL: url,
            canonicalURL: lookupResult?.trackViewURL.flatMap(URL.init(string:)),
            episodeTitle: lookupResult?.trackName,
            episodeID: episodeID,
            directAudioURL: lookupResult?.episodeURL.flatMap(URL.init(string:))
        )

        guard let episode = matcher.bestMatch(in: feed, hints: hints),
              let audioURL = episode.audioURL
        else {
            throw ProviderResolutionError.podcastEpisodeNotFound(url)
        }

        return try DirectPodcastAudioResolver().resolve(
            originalURL: url,
            audioURL: audioURL,
            canonicalURL: lookupResult?.trackViewURL.flatMap(URL.init(string:))
                ?? episode.linkURL
                ?? url,
            title: lookupResult?.trackName ?? episode.title,
            creatorName: lookupResult?.collectionName
                ?? lookupResult?.artistName
                ?? episode.author
                ?? feed.author
                ?? feed.title,
            artworkURL: lookupResult?.bestArtworkURL
                ?? episode.artworkURL
                ?? feed.artworkURL,
            duration: lookupResult?.trackTimeMilliseconds.map { $0 / 1_000 }
                ?? episode.duration,
            publishedAt: ProviderDateParser.parse(lookupResult?.releaseDate)
                ?? episode.publishedAt
        )
    }

    private func episodeLookup(id: String) async throws -> LookupResult? {
        let results = try await lookup(
            id: id,
            entity: "podcastEpisode",
            limit: 1
        )
        return results.first(where: { $0.trackID.map(String.init) == id })
            ?? results.first(where: { $0.episodeURL != nil })
    }

    private func lookup(
        id: String,
        entity: String,
        limit: Int
    ) async throws -> [LookupResult] {
        guard var components = URLComponents(
            url: Self.lookupEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderResolutionError.invalidURL(Self.lookupEndpoint)
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let requestURL = components.url else {
            throw ProviderResolutionError.invalidURL(Self.lookupEndpoint)
        }

        var request = URLRequest(
            url: requestURL,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 15
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await client.data(
            for: request,
            maximumBytes: 3 * 1_024 * 1_024
        )

        do {
            return try JSONDecoder().decode(LookupResponse.self, from: data).results
        } catch {
            throw ProviderResolutionError.malformedResponse(error.localizedDescription)
        }
    }

    private func fetchFeed(_ url: URL) async throws -> RSSFeed {
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue(
            "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("bytes=0-5242879", forHTTPHeaderField: "Range")

        let (data, response) = try await client.data(
            for: request,
            maximumBytes: 5 * 1_024 * 1_024
        )
        return try feedParser.parse(
            data: data,
            sourceURL: response.url ?? url
        )
    }
}

private extension ApplePodcastsLookupResolver {
    struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    struct LookupResult: Decodable {
        let artistName: String?
        let collectionName: String?
        let trackName: String?
        let trackID: Int64?
        let feedURL: String?
        let trackViewURL: String?
        let artworkURL100: String?
        let artworkURL600: String?
        let episodeURL: String?
        let releaseDate: String?
        let trackTimeMilliseconds: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case artistName
            case collectionName
            case trackName
            case trackID = "trackId"
            case feedURL = "feedUrl"
            case trackViewURL = "trackViewUrl"
            case artworkURL100 = "artworkUrl100"
            case artworkURL600 = "artworkUrl600"
            case episodeURL = "episodeUrl"
            case releaseDate
            case trackTimeMilliseconds = "trackTimeMillis"
        }

        var bestArtworkURL: URL? {
            artworkURL600.flatMap(URL.init(string:))
                ?? artworkURL100.flatMap(URL.init(string:))
        }
    }
}
