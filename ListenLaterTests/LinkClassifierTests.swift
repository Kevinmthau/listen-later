import Foundation
import XCTest
@testable import ListenLater

final class LinkClassifierTests: XCTestCase {
    func testClassifiesPlayableLinks() {
        XCTAssertEqual(
            kind("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            .youtubeVideo
        )
        XCTAssertEqual(kind("https://youtu.be/dQw4w9WgXcQ"), .youtubeVideo)
        XCTAssertEqual(
            kind("https://x.com/OpenAI/status/1234567890123456789"),
            .socialVideo
        )
        XCTAssertEqual(
            kind("https://www.instagram.com/reel/DR8LMPxEoiO/"),
            .socialVideo
        )
        XCTAssertEqual(
            kind("https://podcasts.apple.com/us/podcast/show/id123456789?i=1000600000000"),
            .applePodcastsEpisode
        )
        XCTAssertEqual(kind("https://cdn.example.com/episode.mp3"), .audioFile)
        XCTAssertEqual(kind("https://www.example.com/episodes/42"), .webPage)
        // Spotify-hosted RSS shows have ordinary episode pages.
        XCTAssertEqual(
            kind("https://podcasters.spotify.com/pod/show/example/episodes/Pilot-e1abc"),
            .webPage
        )
        XCTAssertEqual(
            kind("https://creators.spotify.com/pod/show/example/episodes/Pilot-e1abc"),
            .webPage
        )
    }

    func testRejectsLinksThatCannotPlayWithAReason() {
        let cases = [
            "http://www.example.com/episode": "https://",
            "https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk": "Spotify",
            "https://spotify.link/abc123": "Spotify",
            "https://www.spotify.com/us/premium/": "Spotify",
            "https://www.tiktok.com/@user/video/1234567890": "TikTok",
            "https://music.apple.com/us/album/1": "Apple Music",
            "https://www.youtube.com/@channel": "YouTube",
            "https://x.com/OpenAI": "X and Instagram",
            "https://www.instagram.com/goodobjects/": "X and Instagram",
            "https://podcasts.apple.com/us/podcast/show/id123456789": "show",
        ]
        for (link, fragment) in cases {
            guard case let .unsupported(reason) = kind(link) else {
                XCTFail("\(link) should be unsupported")
                continue
            }
            XCTAssertTrue(
                reason.contains(fragment),
                "\(link): \"\(reason)\" should mention \(fragment)"
            )
        }
    }

    func testReadsLinksFromTypedPastedAndSharedText() {
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "  https://example.com/episode  ")?.absoluteString,
            "https://example.com/episode"
        )
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "example.com/episode")?.absoluteString,
            "https://example.com/episode"
        )
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "Listen to this https://example.com/ep?x=1 today")?.absoluteString,
            "https://example.com/ep?x=1"
        )
        XCTAssertNil(LinkClassifier.link(fromUserText: ""))
        XCTAssertNil(LinkClassifier.link(fromUserText: "not a link"))
    }

    func testPrefersTheExplicitHTTPSLinkInSharedText() {
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "Via NPR.org https://n.pr/3xYz")?.absoluteString,
            "https://n.pr/3xYz"
        )
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "Listen at example.com/ep/42 today")?.absoluteString,
            "https://example.com/ep/42"
        )
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "Old link: http://example.com/a")?.absoluteString,
            "http://example.com/a",
            "An http link is still returned, so the classifier can say why it's refused."
        )
        XCTAssertEqual(
            LinkClassifier.link(fromUserText: "Via NPR.org http://n.pr/3xYz")?.absoluteString,
            "http://n.pr/3xYz",
            "A site named before an http link isn't the link."
        )
    }

    func testErrorMessagesDoNotRepeatURLs() {
        let url = URL(string: "https://www.example.com/episodes/42?utm_source=x")!
        let errors: [ProviderResolutionError] = [
            .invalidURL(url),
            .unsupportedURL(url),
            .invalidYouTubeVideoURL(url),
            .invalidSocialVideoURL(url),
            .invalidHTTPResponse(url),
            .httpStatus(404, url),
            .httpStatus(503, url),
            .responseTooLarge(url, maximumBytes: 1_000),
            .rssFeedNotFound(url),
            .podcastEpisodeNotFound(url),
            .podcastAudioEnclosureMissing(url),
        ]
        for error in errors {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("example.com"), message)
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(
            ProviderResolutionError.network("").localizedDescription,
            "Couldn’t connect. Check your connection and try again."
        )
    }

    private func kind(_ link: String) -> LinkKind {
        LinkClassifier.classify(URL(string: link)!)
    }
}
