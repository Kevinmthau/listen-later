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
            title: response.displayTitle
                ?? "\(socialURL.platform.displayName) video",
            creatorName: response.displayCreator ?? socialURL.creatorName,
            artworkURL: response.secureThumbnailURL,
            duration: response.validDuration,
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
            return .itemUnavailable("This post is private or needs a login to view.")
        case 404:
            return .itemUnavailable("There’s no video in this post.")
        case 429:
            return .network("The video service is busy. Try again in a moment.")
        case 504:
            return .network("The video service took too long. Try again.")
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

/// `video_url` is always present. The metadata fields are optional so older
/// resolver deployments, which return only the URL, keep working.
private struct ResolveResponse: Decodable {
    let videoURL: String
    let title: String?
    let uploader: String?
    let uploaderID: String?
    let thumbnailURL: String?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case videoURL = "video_url"
        case title
        case uploader
        case uploaderID = "uploader_id"
        case thumbnailURL = "thumbnail_url"
        case duration
    }

    var displayTitle: String? {
        nonEmpty(title)
    }

    var displayCreator: String? {
        if let uploader = nonEmpty(uploader) {
            return uploader
        }
        return nonEmpty(uploaderID).map { "@\($0)" }
    }

    var secureThumbnailURL: URL? {
        guard let thumbnailURL = nonEmpty(thumbnailURL),
              let url = URL(string: thumbnailURL),
              url.scheme?.lowercased() == "https",
              ProviderURLSupport.isHTTPURL(url)
        else {
            return nil
        }
        return url
    }

    var validDuration: TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
