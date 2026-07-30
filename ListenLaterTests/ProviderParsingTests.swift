import Foundation
import XCTest
@testable import ListenLater

final class ProviderParsingTests: XCTestCase {
    func testYouTubeParserRecognizesSupportedURLVariants() throws {
        let videoID = "dQw4w9WgXcQ"
        let encodedRedirect = "https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(videoID)"
        let encodedAttribution = "%2Fwatch%3Fv%3D\(videoID)%26feature%3Dshare"
        let urls = [
            "https://www.youtube.com/watch?v=\(videoID)",
            "https://www.youtube.com./watch?v=\(videoID)",
            "https://youtube.com/watch?feature=shared&v=\(videoID)",
            "https://m.youtube.com/watch?v=\(videoID)&t=42",
            "https://music.youtube.com/watch?v=\(videoID)",
            "https://youtu.be/\(videoID)?si=share-token",
            "https://youtu.be./\(videoID)",
            "https://www.youtu.be/\(videoID)",
            "https://www.youtube.com/embed/\(videoID)",
            "https://www.youtube-nocookie.com/embed/\(videoID)",
            "https://youtube.com/shorts/\(videoID)?feature=share",
            "https://youtube.com/live/\(videoID)",
            "https://youtube.com/v/\(videoID)",
            "https://youtube.com/attribution_link?u=\(encodedAttribution)",
            "https://youtube.com/redirect?q=\(encodedRedirect)",
            "https://youtube.com/#v=\(videoID)"
        ].compactMap(URL.init(string:))

        XCTAssertEqual(urls.count, 16)
        for url in urls {
            XCTAssertTrue(
                YouTubeURLParser.isYouTubeURL(url),
                "Expected YouTube host recognition for \(url)"
            )
            XCTAssertEqual(
                YouTubeURLParser.videoID(from: url),
                videoID,
                "Expected video ID extraction for \(url)"
            )
        }
    }

    func testYouTubeParserRejectsInvalidAndLookalikeURLs() throws {
        let invalidURLs = [
            "https://example.com/watch?v=dQw4w9WgXcQ",
            "https://evilyoutube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.example.com/watch?v=dQw4w9WgXcQ",
            "ftp://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=too-short",
            "https://youtu.be/dQw4w9WgXc!",
            "https://www.youtube.com/embed/",
            "https://www.youtube.com/redirect?q=https%3A%2F%2Fexample.com%2Fwatch%3Fv%3DdQw4w9WgXcQ"
        ].compactMap(URL.init(string:))

        XCTAssertEqual(invalidURLs.count, 9)
        for url in invalidURLs {
            XCTAssertNil(
                YouTubeURLParser.videoID(from: url),
                "Expected video ID rejection for \(url)"
            )
        }

        XCTAssertFalse(
            YouTubeURLParser.isYouTubeURL(
                URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")!
            )
        )
        XCTAssertFalse(
            YouTubeURLParser.isValidVideoID("dQw4w9WgXc!")
        )
        XCTAssertFalse(
            YouTubeURLParser.isValidVideoID("dQw4w9WgXcQextra")
        )
        XCTAssertFalse(
            YouTubeURLParser.isValidVideoID("dQw4w9WgXcé")
        )
    }

    func testYouTubeCanonicalURLValidation() throws {
        XCTAssertEqual(
            YouTubeURLParser.canonicalURL(for: "dQw4w9WgXcQ")?.absoluteString,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        XCTAssertNil(YouTubeURLParser.canonicalURL(for: "invalid"))
    }

    func testSocialVideoParserRecognizesXAndInstagramShareURLs() throws {
        let x = try XCTUnwrap(
            SocialVideoURLParser.parse(
                URL(string: "https://x.com/OpenAI/status/1234567890123456789?s=20")!
            )
        )
        XCTAssertEqual(x.platform, .x)
        XCTAssertEqual(x.mediaID, "1234567890123456789")
        XCTAssertEqual(x.creatorName, "@OpenAI")
        XCTAssertEqual(
            SocialVideoURLParser.canonicalURL(
                for: URL(
                    string: "https://twitter.com/OpenAI/status/1234567890123456789?s=20"
                )!
            )?.absoluteString,
            "https://x.com/OpenAI/status/1234567890123456789"
        )

        let xWithoutCreator = try XCTUnwrap(
            SocialVideoURLParser.parse(
                URL(string: "https://twitter.com/i/status/1234567890123456789")!
            )
        )
        XCTAssertEqual(xWithoutCreator.platform, .x)
        XCTAssertNil(xWithoutCreator.creatorName)

        let instagram = try XCTUnwrap(
            SocialVideoURLParser.parse(
                URL(string: "https://www.instagram.com/share/reel/DR8LMPxEoiO/")!
            )
        )
        XCTAssertEqual(instagram.platform, .instagram)
        XCTAssertEqual(instagram.mediaID, "DR8LMPxEoiO")
    }

    func testSocialVideoParserRejectsLookalikesAndNonVideoPages() {
        let rejected = [
            "https://notx.com/OpenAI/status/1234567890123456789",
            "https://x.com/OpenAI",
            "https://x.com/OpenAI/status/not-a-number",
            "https://instagram.com/openai/",
            "http://x.com/OpenAI/status/1234567890123456789"
        ].compactMap(URL.init(string:))

        for url in rejected {
            XCTAssertNil(
                SocialVideoURLParser.parse(url),
                "Expected social video URL rejection for \(url)"
            )
        }
    }

    func testSocialVideoPlaybackURLUsesUpstreamExpiryWithSafetyWindow() {
        let url = URL(
            string: "https://cdn.example.com/video.mp4?Expires=1700000120"
        )!
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            SocialVideoPlaybackURL.expirationDate(for: url, now: now),
            Date(timeIntervalSince1970: 1_700_000_090)
        )
    }

    func testApplePodcastsParserNormalizesRootDotAndReadsEpisodeID() throws {
        let link = try XCTUnwrap(
            ApplePodcastsLink.parse(
                URL(
                    string: "https://podcasts.apple.com./us/podcast/show/id123456789?i=987654321"
                )!
            )
        )

        XCTAssertEqual(link.showID, "123456789")
        XCTAssertEqual(link.episodeID, "987654321")
    }

    func testProviderURLValidationRejectsLocalAndPrivateTargets() throws {
        let rejected = [
            "http://localhost/episode",
            "http://podcasts.local/episode",
            "http://127.0.0.1/episode",
            "http://127.1/episode",
            "http://2130706433/episode",
            "http://10.0.0.8/episode",
            "http://172.16.4.2/episode",
            "http://192.168.1.10/episode",
            "http://169.254.169.254/metadata",
            "http://[::1]/episode",
            "http://[fd00::1]/episode",
            "https://localhost./episode"
        ].compactMap(URL.init(string:))

        XCTAssertEqual(rejected.count, 12)
        rejected.forEach {
            XCTAssertFalse(ProviderURLSupport.isHTTPURL($0), "\($0) should be rejected")
        }

        XCTAssertTrue(
            ProviderURLSupport.isHTTPURL(
                URL(string: "https://podcasts.example.com/episode")!
            )
        )
        XCTAssertTrue(
            ProviderURLSupport.isHTTPURL(
                URL(string: "https://8.8.8.8/")!
            )
        )
    }

    func testISO8601DurationParsesYouTubeValues() throws {
        let cases: [(String, TimeInterval)] = [
            ("PT0S", 0),
            ("PT45S", 45),
            ("PT2M3S", 123),
            ("PT1H2M3S", 3_723),
            ("P1DT2H3M4S", 93_784),
            ("PT1.5H", 5_400),
            ("PT0.5M", 30),
            ("PT1.25S", 1.25)
        ]

        for (value, expected) in cases {
            let parsed = try XCTUnwrap(
                ProviderDurationParser.iso8601Duration(value)
            )
            XCTAssertEqual(
                parsed,
                expected,
                accuracy: 0.000_1,
                "Unexpected result for \(value)"
            )
        }
    }

    func testISO8601DurationRejectsMalformedValues() throws {
        let malformed: [String?] = [
            nil,
            "",
            "PT",
            "1H2M",
            "P-1D",
            "PT1Sgarbage",
            "pt1h",
            "P1W",
            "P1Y"
        ]

        for value in malformed {
            XCTAssertNil(
                ProviderDurationParser.iso8601Duration(value),
                "Expected malformed duration rejection for \(String(describing: value))"
            )
        }
    }

    func testISO8601DurationRejectsEmptyTimeDesignatorRegression() {
        XCTAssertNil(ProviderDurationParser.iso8601Duration("PT"))
    }
}

final class VideoGrabberProviderAdapterTests: XCTestCase {
    override func tearDown() {
        HTTPClientURLProtocol.responses.removeAll()
        super.tearDown()
    }

    func testResolvePostsXURLWithBearerTokenAndReturnsExpiringVideo() async throws {
        let endpoint = URL(string: "https://resolver.example/resolve")!
        let sourceURL = URL(
            string: "https://x.com/OpenAI/status/1234567890123456789"
        )!
        let videoURL = URL(
            string: "https://cdn.example.com/video.mp4?Expires=4102444800"
        )!
        let responseData = try JSONSerialization.data(withJSONObject: [
            "video_url": videoURL.absoluteString,
            "filename": "tweet_1234567890123456789.mp4",
            "cached": false
        ])
        HTTPClientURLProtocol.responses.set([
            endpoint: .success(data: responseData)
        ])
        let adapter = makeVideoGrabberAdapter(
            endpoint: endpoint,
            apiToken: "test-token"
        )

        let beforeResolve = Date()
        let resolved = try await adapter.resolve(sourceURL)

        XCTAssertEqual(resolved.source, .socialVideo)
        XCTAssertEqual(resolved.title, "X video")
        XCTAssertEqual(resolved.creatorName, "@OpenAI")
        XCTAssertEqual(
            resolved.canonicalURL.absoluteString,
            "https://x.com/OpenAI/status/1234567890123456789"
        )
        XCTAssertEqual(resolved.playback.remoteVideoURL, videoURL)
        let expiresAt = try XCTUnwrap(resolved.playback.remoteVideoExpiresAt)
        XCTAssertGreaterThanOrEqual(
            expiresAt.timeIntervalSince(beforeResolve),
            235
        )
        XCTAssertLessThanOrEqual(
            expiresAt.timeIntervalSince(beforeResolve),
            241
        )

        let request = try XCTUnwrap(HTTPClientURLProtocol.responses.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-token"
        )
        let body = try XCTUnwrap(
            HTTPClientURLProtocol.responses.lastRequestBody
        )
        let bodyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(bodyObject["url"], sourceURL.absoluteString)
    }

    func testResolveMapsUnauthorizedResponseToConfigurationError() async {
        let endpoint = URL(string: "https://resolver.example/resolve")!
        HTTPClientURLProtocol.responses.set([
            endpoint: HTTPClientURLProtocol.Response(
                statusCode: 401,
                headers: [:],
                data: Data()
            )
        ])
        let adapter = makeVideoGrabberAdapter(
            endpoint: endpoint,
            apiToken: "wrong-token"
        )

        await XCTAssertThrowsProviderError(.videoGrabberUnauthorized) {
            _ = try await adapter.resolve(
                URL(
                    string: "https://x.com/OpenAI/status/1234567890123456789"
                )!
            )
        }
    }

    private func makeVideoGrabberAdapter(
        endpoint: URL,
        apiToken: String
    ) -> VideoGrabberProviderAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPClientURLProtocol.self]
        let client = ProviderHTTPClient(
            session: URLSession(configuration: configuration),
            validateEndpoint: { _ in }
        )
        return VideoGrabberProviderAdapter(
            configuration: VideoGrabberConfiguration(
                endpoint: endpoint,
                apiToken: apiToken
            ),
            client: client
        )
    }
}

final class ProviderRegistryTests: XCTestCase {
    func testRegistryDispatchesToFirstMatchingProvider() async throws {
        let url = URL(string: "https://video.example/item")!
        let first = StubMediaProvider(
            source: .youtube,
            acceptedHost: "video.example",
            title: "First provider"
        )
        let second = StubMediaProvider(
            source: .podcast,
            acceptedHost: "video.example",
            title: "Second provider"
        )
        let registry = ProviderRegistry(providers: [first, second])

        XCTAssertEqual(registry.provider(for: url)?.source, .youtube)
        let resolved = try await registry.resolve(url)
        XCTAssertEqual(resolved.title, "First provider")
        XCTAssertEqual(resolved.source, .youtube)
        XCTAssertEqual(resolved.playback.youtubeVideoID, "dQw4w9WgXcQ")
    }

    func testRegistryRejectsInvalidAndUnsupportedURLs() async throws {
        let registry = ProviderRegistry(
            providers: [
                StubMediaProvider(
                    source: .podcast,
                    acceptedHost: "podcasts.example",
                    title: "Podcast"
                )
            ]
        )
        let fileURL = URL(fileURLWithPath: "/tmp/episode.mp3")
        let unsupported = URL(string: "https://example.com/episode")!

        await XCTAssertThrowsProviderError(
            .invalidURL(fileURL)
        ) {
            _ = try await registry.resolve(fileURL)
        }
        await XCTAssertThrowsProviderError(
            .unsupportedURL(unsupported)
        ) {
            _ = try await registry.resolve(unsupported)
        }
    }
}

final class ProviderHTTPClientTests: XCTestCase {
    override func tearDown() {
        HTTPClientURLProtocol.responses.removeAll()
        super.tearDown()
    }

    func testResolvedEndpointFollowsValidatedRedirects() async throws {
        let startURL = URL(string: "https://public.example/start")!
        let finalURL = URL(string: "https://media.example/audio.mp3")!
        HTTPClientURLProtocol.responses.set([
            startURL: .redirect(to: finalURL),
            finalURL: .success()
        ])
        let client = makeClient()

        let resolved = try await client.resolvedEndpointURL(for: startURL)

        XCTAssertEqual(resolved, finalURL)
        XCTAssertEqual(
            HTTPClientURLProtocol.responses.requestedURLs,
            [startURL, finalURL]
        )
    }

    func testResolvedEndpointRejectsRedirectToPrivateAddress() async throws {
        let startURL = URL(string: "https://public.example/start")!
        let privateURL = URL(string: "https://127.0.0.1/audio.mp3")!
        HTTPClientURLProtocol.responses.set([
            startURL: .redirect(to: privateURL)
        ])
        let client = makeClient()

        do {
            _ = try await client.resolvedEndpointURL(for: startURL)
            XCTFail("Expected the private redirect to be rejected.")
        } catch let error as ProviderResolutionError {
            guard case .invalidURL = error else {
                return XCTFail("Unexpected provider error: \(error)")
            }
        }

        XCTAssertEqual(
            HTTPClientURLProtocol.responses.requestedURLs,
            [startURL]
        )
    }

    private func makeClient() -> ProviderHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPClientURLProtocol.self]
        return ProviderHTTPClient(
            session: URLSession(configuration: configuration),
            validateEndpoint: { _ in }
        )
    }
}

private struct StubMediaProvider: MediaProvider {
    let source: ProviderSource
    let acceptedHost: String
    let title: String

    func canResolve(_ url: URL) -> Bool {
        url.host == acceptedHost
    }

    func resolve(_ url: URL) async throws -> ProviderResolvedItem {
        switch source {
        case .podcast:
            return ProviderResolvedItem(
                originalURL: url,
                canonicalURL: url,
                title: title,
                creatorName: "Stub Show",
                artworkURL: nil,
                duration: 120,
                publishedAt: nil,
                source: .podcast,
                playback: .remoteAudio(
                    URL(string: "https://cdn.example/episode.mp3")!
                ),
                isMadeForKids: false
            )
        case .socialVideo:
            return ProviderResolvedItem(
                originalURL: url,
                canonicalURL: url,
                title: title,
                creatorName: "@stub",
                artworkURL: nil,
                duration: nil,
                publishedAt: nil,
                source: .socialVideo,
                playback: .remoteVideo(
                    URL(string: "https://cdn.example/video.mp4")!,
                    expiresAt: Date().addingTimeInterval(240)
                ),
                isMadeForKids: false
            )
        case .youtube:
            return ProviderResolvedItem(
                originalURL: url,
                canonicalURL: URL(
                    string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                )!,
                title: title,
                creatorName: "Stub Channel",
                artworkURL: nil,
                duration: 213,
                publishedAt: nil,
                source: .youtube,
                playback: .youtubeVideoID("dQw4w9WgXcQ"),
                isMadeForKids: false
            )
        }
    }
}

private func XCTAssertThrowsProviderError(
    _ expected: ProviderResolutionError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ProviderResolutionError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private final class HTTPClientURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        static func redirect(to url: URL) -> Self {
            Self(
                statusCode: 302,
                headers: ["Location": url.absoluteString],
                data: Data()
            )
        }

        static func success(data: Data = Data()) -> Self {
            Self(statusCode: 200, headers: [:], data: data)
        }
    }

    final class ResponseStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL: Response] = [:]
        private var requests: [URLRequest] = []
        private var requestBodies: [Data?] = []

        var requestedURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return requests.compactMap(\.url)
        }

        var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests.last
        }

        var lastRequestBody: Data? {
            lock.lock()
            defer { lock.unlock() }
            return requestBodies.last ?? nil
        }

        func set(_ values: [URL: Response]) {
            lock.lock()
            self.values = values
            requests = []
            requestBodies = []
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            values = [:]
            requests = []
            requestBodies = []
            lock.unlock()
        }

        func response(for request: URLRequest) -> Response? {
            let body = Self.bodyData(from: request)
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            requestBodies.append(body)
            return request.url.flatMap { values[$0] }
        }

        private static func bodyData(from request: URLRequest) -> Data? {
            if let body = request.httpBody {
                return body
            }
            guard let stream = request.httpBodyStream else {
                return nil
            }

            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data.isEmpty ? nil : data
        }
    }

    static let responses = ResponseStore()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.responses.response(for: request),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.headers
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        if !stub.data.isEmpty {
            client?.urlProtocol(self, didLoad: stub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
