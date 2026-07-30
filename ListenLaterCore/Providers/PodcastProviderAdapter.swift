import Foundation

struct PodcastProviderAdapter: MediaProvider {
    let source = ProviderSource.podcast

    private let client: ProviderHTTPClient
    private let appleLookup: ApplePodcastsLookupResolver
    private let htmlDiscoverer: HTMLRSSDiscoverer
    private let feedParser = RSSFeedParser()
    private let matcher = RSSMatcher()
    private let directAudioResolver = DirectPodcastAudioResolver()

    init(session: URLSession = .shared) {
        let client = ProviderHTTPClient(session: session)
        self.client = client
        self.appleLookup = ApplePodcastsLookupResolver(client: client)
        self.htmlDiscoverer = HTMLRSSDiscoverer(client: client)
    }

    func canResolve(_ url: URL) -> Bool {
        ProviderURLSupport.isHTTPURL(url)
            && !ProviderURLSupport.isYouTubeHost(url.host)
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard canResolve(url) else {
            throw ProviderResolutionError.unsupportedURL(url)
        }

        if appleLookup.canResolve(url) {
            return try await appleLookup.resolve(url)
        }

        if DirectPodcastAudioResolver.isLikelyAudioURL(url) {
            return try directAudioResolver.resolve(originalURL: url)
        }

        if let headResponse = try? await client.headResponse(for: url),
           DirectPodcastAudioResolver.isAudioMIMEType(headResponse.mimeType)
        {
            return try directAudioResolver.resolve(originalURL: url)
        }

        let (data, response) = try await fetchDocument(url)
        let responseURL = response.url ?? url

        if DirectPodcastAudioResolver.isAudioMIMEType(response.mimeType) {
            return try directAudioResolver.resolve(
                originalURL: url,
                audioURL: responseURL,
                canonicalURL: responseURL
            )
        }

        if Self.looksLikeFeed(data: data, mimeType: response.mimeType) {
            let feed = try feedParser.parse(data: data, sourceURL: responseURL)
            let hints = RSSMatchHints(originalURL: url, canonicalURL: responseURL)

            guard let episode = matcher.bestMatch(in: feed, hints: hints) else {
                throw ProviderResolutionError.podcastEpisodeNotFound(url)
            }
            return try matcher.resolvedItem(
                from: episode,
                feed: feed,
                hints: hints
            )
        }

        let discovery = try htmlDiscoverer.parse(
            data: data,
            pageURL: responseURL
        )

        guard !discovery.feedURLs.isEmpty else {
            throw ProviderResolutionError.rssFeedNotFound(url)
        }

        let hints = RSSMatchHints(
            originalURL: url,
            canonicalURL: discovery.canonicalURL ?? responseURL,
            episodeTitle: discovery.title
        )

        var parsedAtLeastOneFeed = false
        var firstFailure: ProviderResolutionError?

        for feedURL in discovery.feedURLs.prefix(8) {
            do {
                let feed = try await fetchFeed(feedURL)
                parsedAtLeastOneFeed = true

                if let episode = matcher.bestMatch(in: feed, hints: hints) {
                    return try matcher.resolvedItem(
                        from: episode,
                        feed: feed,
                        hints: hints
                    )
                }
            } catch let error as ProviderResolutionError {
                if firstFailure == nil {
                    firstFailure = error
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = .network(error.localizedDescription)
                }
            }
        }

        if parsedAtLeastOneFeed {
            throw ProviderResolutionError.podcastEpisodeNotFound(url)
        }
        throw firstFailure ?? ProviderResolutionError.rssFeedNotFound(url)
    }

    private func fetchDocument(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue(
            "text/html, application/xhtml+xml, application/rss+xml, application/atom+xml, application/xml, text/xml, audio/*;q=0.8, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("bytes=0-5242879", forHTTPHeaderField: "Range")
        return try await client.data(
            for: request,
            maximumBytes: 5 * 1_024 * 1_024
        )
    }

    private func fetchFeed(_ url: URL) async throws -> RSSFeed {
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue(
            "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1",
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

    private static func looksLikeFeed(data: Data, mimeType: String?) -> Bool {
        let normalizedMIMEType = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if [
            "application/rss+xml",
            "application/atom+xml",
            "application/rdf+xml",
            "application/xml",
            "text/xml"
        ].contains(normalizedMIMEType) {
            return true
        }

        let prefix = String(
            decoding: data.prefix(1_024),
            as: UTF8.self
        ).lowercased()
        return prefix.contains("<rss")
            || prefix.contains("<feed")
            || prefix.contains("<rdf:rdf")
    }
}
