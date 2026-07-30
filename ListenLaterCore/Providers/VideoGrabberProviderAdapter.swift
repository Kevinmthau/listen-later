import Foundation

struct VideoGrabberConfiguration: Hashable, Sendable {
    static let defaultEndpoint = URL(
        string: "https://twitter-video-grabber-production.up.railway.app/resolve"
    )!

    let endpoint: URL
    let apiToken: String

    init(
        endpoint: URL = defaultEndpoint,
        apiToken: String = ""
    ) {
        self.endpoint = endpoint
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct VideoGrabberProviderAdapter: MediaProvider {
    let source = ProviderSource.socialVideo

    private let configuration: VideoGrabberConfiguration
    private let client: ProviderHTTPClient

    init(
        endpoint: URL = VideoGrabberConfiguration.defaultEndpoint,
        apiToken: String = "",
        session: URLSession? = nil
    ) {
        self.init(
            configuration: VideoGrabberConfiguration(
                endpoint: endpoint,
                apiToken: apiToken
            ),
            client: ProviderHTTPClient(
                session: session ?? Self.makeEphemeralSession()
            )
        )
    }

    init(
        configuration: VideoGrabberConfiguration,
        client: ProviderHTTPClient
    ) {
        self.configuration = configuration
        self.client = client
    }

    func canResolve(_ url: URL) -> Bool {
        SocialVideoURLParser.isSupported(url)
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard ProviderURLSupport.isHTTPURL(url),
              let socialURL = SocialVideoURLParser.parse(url)
        else {
            throw ProviderResolutionError.invalidSocialVideoURL(url)
        }
        guard configuration.endpoint.scheme?.lowercased() == "https",
              ProviderURLSupport.isHTTPURL(configuration.endpoint)
        else {
            throw ProviderResolutionError.invalidURL(configuration.endpoint)
        }

        var request = URLRequest(
            url: configuration.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiToken.isEmpty {
            request.setValue(
                "Bearer \(configuration.apiToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.httpBody = try JSONEncoder().encode(ResolveRequest(url: url))

        let data: Data
        do {
            (data, _) = try await client.data(
                for: request,
                maximumBytes: 64 * 1_024
            )
        } catch let error as ProviderResolutionError {
            throw map(error)
        }

        let response: ResolveResponse
        do {
            response = try JSONDecoder().decode(ResolveResponse.self, from: data)
        } catch {
            throw ProviderResolutionError.malformedResponse(
                "video-grabber returned invalid JSON: \(error.localizedDescription)"
            )
        }

        guard let videoURL = URL(string: response.videoURL),
              videoURL.scheme?.lowercased() == "https",
              ProviderURLSupport.isHTTPURL(videoURL)
        else {
            throw ProviderResolutionError.malformedResponse(
                "video-grabber did not return a secure public video URL."
            )
        }

        return ProviderResolvedItem(
            originalURL: url,
            canonicalURL: SocialVideoURLParser.canonicalURL(for: url) ?? url,
            title: "\(socialURL.platform.displayName) video",
            creatorName: socialURL.creatorName,
            artworkURL: nil,
            duration: nil,
            publishedAt: nil,
            source: .socialVideo,
            playback: .remoteVideo(
                videoURL,
                expiresAt: SocialVideoPlaybackURL.expirationDate(for: videoURL)
            ),
            isMadeForKids: false
        )
    }

    private func map(
        _ error: ProviderResolutionError
    ) -> ProviderResolutionError {
        guard case let .httpStatus(status, _) = error else {
            return error
        }
        switch status {
        case 401:
            return .videoGrabberUnauthorized
        case 403:
            return .itemUnavailable(
                "This post is private, protected, or requires a video-grabber login."
            )
        case 404:
            return .itemUnavailable("No downloadable video was found in this post.")
        case 429:
            return .network("The video resolver is busy or rate limited. Try again shortly.")
        case 504:
            return .network("The video resolver timed out. Try again.")
        default:
            return error
        }
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

private struct ResolveRequest: Encodable {
    let url: String

    init(url: URL) {
        self.url = url.absoluteString
    }
}

private struct ResolveResponse: Decodable {
    let videoURL: String

    enum CodingKeys: String, CodingKey {
        case videoURL = "video_url"
    }
}
