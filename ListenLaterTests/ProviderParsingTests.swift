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
