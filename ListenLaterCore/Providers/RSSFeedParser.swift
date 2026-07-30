import Foundation

struct RSSFeed: Hashable, Sendable {
    let sourceURL: URL
    let title: String?
    let author: String?
    let artworkURL: URL?
    let episodes: [RSSEpisode]
}

struct RSSEpisode: Hashable, Sendable {
    let title: String?
    let author: String?
    let linkURL: URL?
    let guid: String?
    let audioURL: URL?
    let artworkURL: URL?
    let duration: TimeInterval?
    let publishedAt: Date?
}

struct RSSFeedParser: Sendable {
    func parse(data: Data, sourceURL: URL) throws -> RSSFeed {
        let delegate = RSSXMLParserDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription
                ?? delegate.parsingError?.localizedDescription
                ?? "The RSS document is not valid XML."
            throw ProviderResolutionError.malformedResponse(message)
        }

        return RSSFeed(
            sourceURL: sourceURL,
            title: ProviderTextSupport.cleanedTitle(delegate.feedTitle),
            author: ProviderTextSupport.cleanedTitle(delegate.feedAuthor),
            artworkURL: delegate.feedArtworkURL,
            episodes: delegate.episodes
        )
    }
}

private final class RSSXMLParserDelegate: NSObject, XMLParserDelegate {
    let sourceURL: URL

    var feedTitle: String?
    var feedAuthor: String?
    var feedArtworkURL: URL?
    var episodes: [RSSEpisode] = []
    var parsingError: Error?

    private var elementStack: [String] = []
    private var textStack: [String] = []
    private var episodeDraft: EpisodeDraft?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = Self.localName(elementName: elementName, qualifiedName: qName)
        elementStack.append(localName)
        textStack.append("")

        if localName == "item" || localName == "entry" {
            episodeDraft = EpisodeDraft()
            return
        }

        var attributes: [String: String] = [:]
        for (name, value) in attributeDict {
            attributes[name.lowercased()] = ProviderTextSupport.decodeHTMLEntities(value)
        }

        if localName == "enclosure",
           let rawURL = attributes["url"] ?? attributes["href"],
           let url = ProviderURLSupport.resolvedURL(rawURL, relativeTo: sourceURL),
           (
               attributes["type"] == nil
                   || Self.isAudioMedia(
                       url: url,
                       mimeType: attributes["type"],
                       medium: nil
                   )
           ),
           episodeDraft?.audioURL == nil
        {
            episodeDraft?.audioURL = url
            return
        }

        if localName == "content",
           let rawURL = attributes["url"] ?? attributes["href"],
           let url = ProviderURLSupport.resolvedURL(rawURL, relativeTo: sourceURL),
           Self.isAudioMedia(
               url: url,
               mimeType: attributes["type"],
               medium: attributes["medium"]
           ),
           episodeDraft?.audioURL == nil
        {
            episodeDraft?.audioURL = url
        }

        if localName == "link",
           let rawURL = attributes["href"],
           let url = ProviderURLSupport.resolvedURL(rawURL, relativeTo: sourceURL)
        {
            let relationship = attributes["rel"]?.lowercased()
            let mimeType = attributes["type"]?.lowercased()
            if relationship == "enclosure" || mimeType?.hasPrefix("audio/") == true {
                if episodeDraft?.audioURL == nil {
                    episodeDraft?.audioURL = url
                }
            } else if episodeDraft != nil,
                      relationship == nil || relationship == "alternate",
                      episodeDraft?.linkURL == nil
            {
                episodeDraft?.linkURL = url
            }
        }

        if localName == "image",
           let rawURL = attributes["href"] ?? attributes["url"],
           let url = ProviderURLSupport.resolvedURL(rawURL, relativeTo: sourceURL)
        {
            if episodeDraft != nil {
                episodeDraft?.artworkURL = url
            } else if feedArtworkURL == nil {
                feedArtworkURL = url
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1].append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1].append(
            String(decoding: CDATABlock, as: UTF8.self)
        )
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = Self.localName(elementName: elementName, qualifiedName: qName)
        let text = textStack.popLast()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        defer {
            _ = elementStack.popLast()
        }

        if localName == "item" || localName == "entry" {
            if let draft = episodeDraft {
                episodes.append(draft.makeEpisode())
            }
            episodeDraft = nil
            return
        }

        if episodeDraft != nil {
            applyEpisodeValue(text, for: localName)
        } else {
            applyFeedValue(text, for: localName)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parsingError = parseError
    }

    private func applyEpisodeValue(_ value: String, for localName: String) {
        guard !value.isEmpty else { return }

        switch localName {
        case "title":
            if episodeDraft?.title == nil {
                episodeDraft?.title = value
            }
        case "link":
            if episodeDraft?.linkURL == nil {
                episodeDraft?.linkURL = ProviderURLSupport.resolvedURL(
                    value,
                    relativeTo: sourceURL
                )
            }
        case "guid", "id":
            if episodeDraft?.guid == nil {
                episodeDraft?.guid = value
            }
        case "author", "creator":
            if episodeDraft?.author == nil {
                episodeDraft?.author = value
            }
        case "name":
            if elementStack.dropLast().contains("author"),
               episodeDraft?.author == nil
            {
                episodeDraft?.author = value
            }
        case "duration":
            if episodeDraft?.duration == nil {
                episodeDraft?.duration = ProviderDurationParser.podcastDuration(value)
            }
        case "pubdate", "published":
            if episodeDraft?.publishedAt == nil {
                episodeDraft?.publishedAt = ProviderDateParser.parse(value)
            }
        case "updated":
            if episodeDraft?.publishedAt == nil {
                episodeDraft?.publishedAt = ProviderDateParser.parse(value)
            }
        default:
            break
        }
    }

    private func applyFeedValue(_ value: String, for localName: String) {
        guard !value.isEmpty else { return }

        switch localName {
        case "title":
            if feedTitle == nil {
                feedTitle = value
            }
        case "author", "creator":
            if feedAuthor == nil {
                feedAuthor = value
            }
        case "name":
            if elementStack.dropLast().contains("author"), feedAuthor == nil {
                feedAuthor = value
            }
        case "url":
            if elementStack.dropLast().contains("image"),
               feedArtworkURL == nil
            {
                feedArtworkURL = ProviderURLSupport.resolvedURL(
                    value,
                    relativeTo: sourceURL
                )
            }
        case "logo", "icon":
            if feedArtworkURL == nil {
                feedArtworkURL = ProviderURLSupport.resolvedURL(
                    value,
                    relativeTo: sourceURL
                )
            }
        default:
            break
        }
    }

    private static func localName(
        elementName: String,
        qualifiedName: String?
    ) -> String {
        let rawName = qualifiedName ?? elementName
        return rawName
            .split(separator: ":")
            .last?
            .lowercased()
            ?? rawName.lowercased()
    }

    private static func isAudioMedia(
        url: URL,
        mimeType: String?,
        medium: String?
    ) -> Bool {
        if medium?.lowercased() == "audio" {
            return true
        }
        if let mimeType = mimeType?.lowercased(),
           mimeType.hasPrefix("audio/")
                || mimeType == "application/ogg"
                || mimeType == "video/mp4"
        {
            return true
        }

        return DirectPodcastAudioResolver.isLikelyAudioURL(url)
    }

    private struct EpisodeDraft {
        var title: String?
        var author: String?
        var linkURL: URL?
        var guid: String?
        var audioURL: URL?
        var artworkURL: URL?
        var duration: TimeInterval?
        var publishedAt: Date?

        func makeEpisode() -> RSSEpisode {
            RSSEpisode(
                title: ProviderTextSupport.cleanedTitle(title),
                author: ProviderTextSupport.cleanedTitle(author),
                linkURL: linkURL,
                guid: guid?.trimmingCharacters(in: .whitespacesAndNewlines),
                audioURL: audioURL,
                artworkURL: artworkURL,
                duration: duration,
                publishedAt: publishedAt
            )
        }
    }
}
