import Foundation

struct YouTubeAPIConfiguration: Hashable, Sendable {
    static let defaultEndpoint = URL(string: "https://www.googleapis.com/youtube/v3/videos")!
    static let defaultOEmbedEndpoint = URL(string: "https://www.youtube.com/oembed")!

    let apiKey: String
    let endpoint: URL
    let oEmbedEndpoint: URL

    init(
        apiKey: String,
        endpoint: URL = defaultEndpoint,
        oEmbedEndpoint: URL = defaultOEmbedEndpoint
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint
        self.oEmbedEndpoint = oEmbedEndpoint
    }

    static func fromInfoDictionary(
        bundle: Bundle = .main,
        key: String = "YOUTUBE_API_KEY"
    ) -> Self {
        let apiKey = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
        return Self(apiKey: apiKey)
    }
}

struct YouTubeProviderAdapter: MediaProvider {
    let source = ProviderSource.youtube

    private let configuration: YouTubeAPIConfiguration
    private let client: ProviderHTTPClient

    init(
        apiKey: String,
        session: URLSession? = nil
    ) {
        self.init(
            configuration: YouTubeAPIConfiguration(apiKey: apiKey),
            session: session
        )
    }

    init(
        configuration: YouTubeAPIConfiguration,
        session: URLSession? = nil
    ) {
        self.init(
            configuration: configuration,
            client: ProviderHTTPClient(
                session: session ?? Self.makeEphemeralSession()
            )
        )
    }

    init(
        configuration: YouTubeAPIConfiguration,
        client: ProviderHTTPClient
    ) {
        self.configuration = configuration
        self.client = client
    }

    func canResolve(_ url: URL) -> Bool {
        YouTubeURLParser.isYouTubeURL(url)
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        guard ProviderURLSupport.isHTTPURL(url),
              YouTubeURLParser.isYouTubeURL(url)
        else {
            throw ProviderResolutionError.invalidURL(url)
        }

        guard let videoID = YouTubeURLParser.videoID(from: url) else {
            throw ProviderResolutionError.invalidYouTubeVideoURL(url)
        }
        guard let canonicalURL = YouTubeURLParser.canonicalURL(for: videoID) else {
            throw ProviderResolutionError.invalidYouTubeVideoURL(url)
        }

        // Playback only needs the video ID. When a build has no Data API key,
        // YouTube's public oEmbed response still lets the queue validate the
        // video and show its title, channel and thumbnail.
        if configuration.apiKey.isEmpty {
            return try await resolveWithOEmbed(
                originalURL: url,
                canonicalURL: canonicalURL,
                videoID: videoID
            )
        }

        let requestURL = try metadataURL(videoID: videoID)
        var request = URLRequest(
            url: requestURL,
            // A policy refresh must reach YouTube rather than re-stamping an
            // arbitrarily old local response as newly fetched metadata.
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let (data, _) = try await client.data(
            for: request,
            maximumBytes: 2 * 1_024 * 1_024
        )

        let response: VideosResponse
        do {
            response = try JSONDecoder().decode(VideosResponse.self, from: data)
        } catch {
            throw ProviderResolutionError.malformedResponse(error.localizedDescription)
        }

        guard let video = response.items.first(where: { $0.id == videoID }) else {
            throw ProviderResolutionError.itemUnavailable(
                "YouTube did not return public metadata for video \(videoID)."
            )
        }

        if let uploadStatus = video.status?.uploadStatus?.lowercased(),
           ["deleted", "failed", "rejected"].contains(uploadStatus)
        {
            throw ProviderResolutionError.itemUnavailable(
                "YouTube reports upload status “\(uploadStatus)”."
            )
        }

        if video.status?.privacyStatus?.lowercased() == "private" {
            throw ProviderResolutionError.itemUnavailable(
                "The YouTube video is private."
            )
        }

        let title = ProviderTextSupport.cleanedTitle(video.snippet?.title)
            ?? "YouTube Video"

        return ProviderResolvedItem(
            originalURL: url,
            canonicalURL: canonicalURL,
            title: title,
            creatorName: ProviderTextSupport.cleanedTitle(video.snippet?.channelTitle),
            artworkURL: video.snippet?.bestThumbnailURL,
            duration: ProviderDurationParser.iso8601Duration(video.contentDetails?.duration),
            publishedAt: ProviderDateParser.parse(video.snippet?.publishedAt),
            source: .youtube,
            playback: .youtubeVideoID(videoID),
            isMadeForKids: video.status?.madeForKids ?? false,
            requiresOfficialYouTubeApp:
                video.status?.embeddable != true
                || video.status?.madeForKids == nil
        )
    }

    private func resolveWithOEmbed(
        originalURL: URL,
        canonicalURL: URL,
        videoID: String
    ) async throws -> ProviderResolvedItem {
        let requestURL = try oEmbedMetadataURL(canonicalURL: canonicalURL)
        var request = URLRequest(
            url: requestURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            (data, _) = try await client.data(
                for: request,
                maximumBytes: 256 * 1_024
            )
        } catch let error as ProviderResolutionError {
            if case let .httpStatus(status, _) = error,
               [400, 401, 403, 404].contains(status)
            {
                throw ProviderResolutionError.itemUnavailable(
                    "YouTube did not return public metadata for this video."
                )
            }
            throw error
        }

        let response: OEmbedResponse
        do {
            response = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        } catch {
            throw ProviderResolutionError.malformedResponse(error.localizedDescription)
        }

        guard response.type.lowercased() == "video" else {
            throw ProviderResolutionError.itemUnavailable(
                "This YouTube link doesn’t point to a public video."
            )
        }

        return ProviderResolvedItem(
            originalURL: originalURL,
            canonicalURL: canonicalURL,
            title: ProviderTextSupport.cleanedTitle(response.title)
                ?? "YouTube Video",
            creatorName: ProviderTextSupport.cleanedTitle(response.authorName),
            artworkURL: response.secureThumbnailURL,
            duration: nil,
            publishedAt: nil,
            source: .youtube,
            playback: .youtubeVideoID(videoID),
            isMadeForKids: false,
            // YouTube policy requires the Data API Made For Kids lookup
            // before an app embeds each video. oEmbed does not expose it, so
            // this item stays useful in the queue but opens in YouTube.
            requiresOfficialYouTubeApp: true
        )
    }

    private func metadataURL(videoID: String) throws -> URL {
        guard var components = URLComponents(
            url: configuration.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderResolutionError.invalidURL(configuration.endpoint)
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "part", value: "snippet,contentDetails,status"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(
                name: "fields",
                value: "items(id,snippet(title,channelTitle,publishedAt,thumbnails),contentDetails(duration),status(uploadStatus,privacyStatus,embeddable,madeForKids))"
            ),
            URLQueryItem(name: "key", value: configuration.apiKey)
        ])
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ProviderResolutionError.invalidURL(configuration.endpoint)
        }
        return url
    }

    private func oEmbedMetadataURL(canonicalURL: URL) throws -> URL {
        guard var components = URLComponents(
            url: configuration.oEmbedEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderResolutionError.invalidURL(configuration.oEmbedEndpoint)
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "url", value: canonicalURL.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ])
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ProviderResolutionError.invalidURL(configuration.oEmbedEndpoint)
        }
        return url
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

private extension YouTubeProviderAdapter {
    struct OEmbedResponse: Decodable {
        let title: String?
        let authorName: String?
        let thumbnailURL: String?
        let type: String

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
            case type
        }

        var secureThumbnailURL: URL? {
            guard let thumbnailURL,
                  let url = URL(string: thumbnailURL),
                  ProviderURLSupport.isHTTPURL(url)
            else {
                return nil
            }
            return url
        }
    }

    struct VideosResponse: Decodable {
        let items: [Video]
    }

    struct Video: Decodable {
        let id: String
        let snippet: Snippet?
        let contentDetails: ContentDetails?
        let status: Status?
    }

    struct Snippet: Decodable {
        let publishedAt: String?
        let title: String?
        let channelTitle: String?
        let thumbnails: [String: Thumbnail]?

        var bestThumbnailURL: URL? {
            let preference = ["maxres", "standard", "high", "medium", "default"]
            for key in preference {
                if let rawURL = thumbnails?[key]?.url,
                   let url = URL(string: rawURL)
                {
                    return url
                }
            }
            return nil
        }
    }

    struct Thumbnail: Decodable {
        let url: String?
    }

    struct ContentDetails: Decodable {
        let duration: String?
    }

    struct Status: Decodable {
        let uploadStatus: String?
        let privacyStatus: String?
        let embeddable: Bool?
        let madeForKids: Bool?
    }
}
