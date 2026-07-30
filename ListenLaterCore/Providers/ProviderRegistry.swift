import Foundation

struct ProviderRegistry: Sendable {
    private let providers: [any MediaProvider]
    private let validatesResolvedEndpoints: Bool

    init(providers: [any MediaProvider]) {
        self.providers = providers
        self.validatesResolvedEndpoints = false
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
        self.validatesResolvedEndpoints = true
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
        guard validatesResolvedEndpoints else { return resolved }

        if let artworkURL = resolved.artworkURL {
            try await ProviderEndpointValidator.validate(artworkURL)
        }
        if case let .remoteAudio(audioURL) = resolved.playback {
            try await ProviderEndpointValidator.validate(audioURL)
        }
        return resolved
    }
}
