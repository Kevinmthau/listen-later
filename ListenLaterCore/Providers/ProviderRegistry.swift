import Foundation

struct ProviderRegistry: Sendable {
    private let providers: [any MediaProvider]
    private let endpointClient: ProviderHTTPClient?

    init(providers: [any MediaProvider]) {
        self.providers = providers
        self.endpointClient = nil
    }

    init(
        youtubeAPIKey: String,
        podcastSession: URLSession = .shared,
        youtubeSession: URLSession? = nil
    ) {
        self.providers = [
            YouTubeProviderAdapter(
                apiKey: youtubeAPIKey,
                session: youtubeSession
            ),
            PodcastProviderAdapter(session: podcastSession)
        ]
        self.endpointClient = ProviderHTTPClient(session: podcastSession)
    }

    func provider(for url: URL) -> (any MediaProvider)? {
        providers.first { $0.canResolve(url) }
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard ProviderURLSupport.isHTTPURL(url) else {
            throw ProviderResolutionError.invalidURL(url)
        }
        guard let provider = provider(for: url) else {
            throw ProviderResolutionError.unsupportedURL(url)
        }
        let resolved = try await provider.resolve(url)
        guard let endpointClient else { return resolved }

        let artworkURL: URL?
        if let candidate = resolved.artworkURL {
            artworkURL = try? await endpointClient.resolvedEndpointURL(
                for: candidate
            )
        } else {
            artworkURL = nil
        }

        let playback: ProviderPlaybackReference
        switch resolved.playback {
        case let .remoteAudio(candidate):
            playback = .remoteAudio(
                try await endpointClient.resolvedEndpointURL(for: candidate)
            )
        case .youtubeVideoID:
            playback = resolved.playback
        }

        return ProviderResolvedItem(
            originalURL: resolved.originalURL,
            canonicalURL: resolved.canonicalURL,
            title: resolved.title,
            creatorName: resolved.creatorName,
            artworkURL: artworkURL,
            duration: resolved.duration,
            publishedAt: resolved.publishedAt,
            source: resolved.source,
            playback: playback,
            isMadeForKids: resolved.isMadeForKids
        )
    }
}
