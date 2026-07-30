import Foundation
import XCTest
@testable import ListenLater

final class RSSFeedTests: XCTestCase {
    private let sourceURL = URL(string: "https://feeds.example.com/show.xml")!

    func testRSSFixtureParsesFeedAndEpisodeMetadata() throws {
        let feed = try RSSFeedParser().parse(
            data: Data(RSSFixtures.rss.utf8),
            sourceURL: sourceURL
        )

        XCTAssertEqual(feed.title, "Test & Talk")
        XCTAssertEqual(feed.author, "Feed Host")
        XCTAssertEqual(
            feed.artworkURL?.absoluteString,
            "https://images.example.com/show.jpg"
        )
        XCTAssertEqual(feed.episodes.count, 3)

        let episode = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(episode.title, "Designing & Building Calm")
        XCTAssertEqual(episode.author, "Episode Host")
        XCTAssertEqual(
            episode.linkURL?.absoluteString,
            "https://example.com/episodes/calm?utm_source=rss"
        )
        XCTAssertEqual(episode.guid, "episode-calm-42")
        XCTAssertEqual(
            episode.audioURL?.absoluteString,
            "https://cdn.example.com/calm.mp3"
        )
        XCTAssertEqual(try XCTUnwrap(episode.duration), 3_723)
        XCTAssertNotNil(episode.publishedAt)
    }

    func testAtomFixtureParsesAlternateAndEnclosureLinks() throws {
        let feed = try RSSFeedParser().parse(
            data: Data(RSSFixtures.atom.utf8),
            sourceURL: URL(string: "https://feeds.example.com/atom/feed.xml")!
        )

        XCTAssertEqual(feed.title, "Atom Conversations")
        XCTAssertEqual(feed.author, "Atom Network")
        XCTAssertEqual(
            feed.artworkURL?.absoluteString,
            "https://feeds.example.com/art/atom.png"
        )

        let episode = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(episode.title, "An Atom Episode")
        XCTAssertEqual(episode.author, "Atom Host")
        XCTAssertEqual(
            episode.linkURL?.absoluteString,
            "https://example.com/atom/episode-7"
        )
        XCTAssertEqual(
            episode.audioURL?.absoluteString,
            "https://feeds.example.com/audio/atom-7.m4a"
        )
        XCTAssertEqual(try XCTUnwrap(episode.duration), 754)
    }

    func testRSSParserPreservesCDATAValues() throws {
        let xml = """
        <rss version="2.0">
          <channel>
            <title><![CDATA[Signals & Threads]]></title>
            <item>
              <title><![CDATA[Designing Calm & Resilient Systems]]></title>
              <author><![CDATA[Casey & Morgan]]></author>
              <enclosure url="https://cdn.example.com/cdata.mp3" type="audio/mpeg"/>
            </item>
          </channel>
        </rss>
        """

        let feed = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            sourceURL: sourceURL
        )
        let episode = try XCTUnwrap(feed.episodes.first)

        XCTAssertEqual(feed.title, "Signals & Threads")
        XCTAssertEqual(episode.title, "Designing Calm & Resilient Systems")
        XCTAssertEqual(episode.author, "Casey & Morgan")
    }

    func testMatcherUsesCanonicalURLIgnoringTrackingParameters() throws {
        let feed = try parsedRSSFeed()
        let hints = RSSMatchHints(
            originalURL: URL(string: "https://share.example/calm")!,
            canonicalURL: URL(
                string: "https://example.com/episodes/calm?utm_campaign=share"
            )!
        )

        let match = RSSMatcher().bestMatch(in: feed, hints: hints)
        XCTAssertEqual(match?.guid, "episode-calm-42")
    }

    func testMatcherUsesTitleEpisodeIDAndDirectAudioHints() throws {
        let feed = try parsedRSSFeed()
        let matcher = RSSMatcher()

        let titleMatch = matcher.bestMatch(
            in: feed,
            hints: RSSMatchHints(
                originalURL: URL(string: "https://example.com/shared")!,
                episodeTitle: "Designing and Building Calm"
            )
        )
        XCTAssertEqual(titleMatch?.guid, "episode-calm-42")

        let idMatch = matcher.bestMatch(
            in: feed,
            hints: RSSMatchHints(
                originalURL: URL(string: "https://example.com/shared")!,
                episodeID: "different-99"
            )
        )
        XCTAssertEqual(idMatch?.guid, "episode-different-99")

        let audioMatch = matcher.bestMatch(
            in: feed,
            hints: RSSMatchHints(
                originalURL: URL(string: "https://example.com/shared")!,
                directAudioURL: URL(
                    string: "https://cdn.example.com/different.mp3?utm_source=copy"
                )
            )
        )
        XCTAssertEqual(audioMatch?.guid, "episode-different-99")
    }

    func testMatcherIgnoresEpisodesWithoutAudioAndRejectsWeakMatch() throws {
        let feed = try parsedRSSFeed()
        let hints = RSSMatchHints(
            originalURL: URL(string: "https://unrelated.example/quantum-bananas")!,
            episodeTitle: "Quantum Bananas"
        )

        XCTAssertNil(RSSMatcher().bestMatch(in: feed, hints: hints))

        let missingAudioHints = RSSMatchHints(
            originalURL: URL(string: "https://example.com/episodes/no-audio")!
        )
        XCTAssertNil(
            RSSMatcher().bestMatch(in: feed, hints: missingAudioHints)
        )
    }

    func testMatcherBuildsResolvedPodcastUsingFeedFallbacks() throws {
        let feed = try parsedRSSFeed()
        let hints = RSSMatchHints(
            originalURL: URL(string: "https://example.com/episodes/calm")!,
            episodeTitle: "Designing & Building Calm"
        )
        let episode = try XCTUnwrap(
            RSSMatcher().bestMatch(in: feed, hints: hints)
        )

        let resolved = try RSSMatcher().resolvedItem(
            from: episode,
            feed: feed,
            hints: hints
        )

        XCTAssertEqual(resolved.source, .podcast)
        XCTAssertEqual(resolved.title, "Designing & Building Calm")
        XCTAssertEqual(resolved.creatorName, "Episode Host")
        XCTAssertEqual(resolved.artworkURL, feed.artworkURL)
        XCTAssertEqual(
            resolved.playback.remoteAudioURL?.absoluteString,
            "https://cdn.example.com/calm.mp3"
        )
        XCTAssertEqual(try XCTUnwrap(resolved.duration), 3_723)
    }

    func testMalformedRSSFixtureThrowsMalformedResponse() throws {
        XCTAssertThrowsError(
            try RSSFeedParser().parse(
                data: Data("<rss><channel><item></rss>".utf8),
                sourceURL: sourceURL
            )
        ) { error in
            guard let providerError = error as? ProviderResolutionError,
                  case .malformedResponse = providerError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func parsedRSSFeed() throws -> RSSFeed {
        try RSSFeedParser().parse(
            data: Data(RSSFixtures.rss.utf8),
            sourceURL: sourceURL
        )
    }
}

private enum RSSFixtures {
    static let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
         xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>Test &amp; Talk</title>
        <itunes:author>Feed Host</itunes:author>
        <itunes:image href="https://images.example.com/show.jpg"/>
        <item>
          <title>Designing &amp; Building Calm</title>
          <dc:creator>Episode Host</dc:creator>
          <link>https://example.com/episodes/calm?utm_source=rss</link>
          <guid>episode-calm-42</guid>
          <enclosure url="https://cdn.example.com/calm.mp3"
                     type="audio/mpeg"
                     length="123456"/>
          <itunes:duration>01:02:03</itunes:duration>
          <pubDate>Thu, 30 Jul 2026 14:15:00 +0000</pubDate>
        </item>
        <item>
          <title>A Different Episode</title>
          <link>https://example.com/episodes/different</link>
          <guid>episode-different-99</guid>
          <enclosure url="https://cdn.example.com/different.mp3?utm_medium=rss"
                     type="audio/mpeg"/>
          <itunes:duration>12:34</itunes:duration>
        </item>
        <item>
          <title>Episode Without Audio</title>
          <link>https://example.com/episodes/no-audio</link>
          <guid>episode-no-audio</guid>
        </item>
      </channel>
    </rss>
    """

    static let atom = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <title>Atom Conversations</title>
      <author><name>Atom Network</name></author>
      <logo>/art/atom.png</logo>
      <entry>
        <title>An Atom Episode</title>
        <author><name>Atom Host</name></author>
        <id>tag:example.com,2026:atom-7</id>
        <link rel="alternate" href="https://example.com/atom/episode-7"/>
        <link rel="enclosure" type="audio/mp4" href="../audio/atom-7.m4a"/>
        <itunes:duration>12:34</itunes:duration>
        <published>2026-07-29T12:00:00Z</published>
      </entry>
    </feed>
    """
}
