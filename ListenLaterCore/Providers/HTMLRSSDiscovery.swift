import Foundation

struct HTMLRSSDiscoveryResult: Hashable, Sendable {
    let pageURL: URL
    let canonicalURL: URL?
    let title: String?
    let feedURLs: [URL]
}

struct HTMLRSSDiscoverer: Sendable {
    private let client: ProviderHTTPClient

    init(session: URLSession = .shared) {
        self.client = ProviderHTTPClient(session: session)
    }

    init(client: ProviderHTTPClient) {
        self.client = client
    }

    func discover(at pageURL: URL) async throws -> HTMLRSSDiscoveryResult {
        guard ProviderURLSupport.isHTTPURL(pageURL),
              !ProviderURLSupport.isYouTubeHost(pageURL.host)
        else {
            throw ProviderResolutionError.invalidURL(pageURL)
        }

        var request = URLRequest(
            url: pageURL,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 15
        )
        request.setValue(
            "text/html, application/xhtml+xml;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("bytes=0-4194303", forHTTPHeaderField: "Range")

        let (data, response) = try await client.data(
            for: request,
            maximumBytes: 4 * 1_024 * 1_024
        )
        return try parse(data: data, pageURL: response.url ?? pageURL)
    }

    func parse(data: Data, pageURL: URL) throws -> HTMLRSSDiscoveryResult {
        guard !ProviderURLSupport.isYouTubeHost(pageURL.host) else {
            throw ProviderResolutionError.unsupportedURL(pageURL)
        }

        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw ProviderResolutionError.malformedResponse(
                "The HTML document could not be decoded."
            )
        }

        let baseURL = HTMLTagParser.tags(named: "base", in: html)
            .compactMap { $0["href"] }
            .compactMap { ProviderURLSupport.resolvedURL($0, relativeTo: pageURL) }
            .first
            ?? pageURL

        var canonicalURL: URL?
        var feedURLs: [URL] = []
        var seenFeedURLs = Set<String>()

        for attributes in HTMLTagParser.tags(named: "link", in: html) {
            let relationships = Set(
                (attributes["rel"] ?? "")
                    .lowercased()
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
            )

            guard let href = attributes["href"],
                  let resolvedURL = ProviderURLSupport.resolvedURL(
                      href,
                      relativeTo: baseURL
                  ),
                  ProviderURLSupport.isHTTPURL(resolvedURL)
            else {
                continue
            }

            if relationships.contains("canonical"), canonicalURL == nil {
                canonicalURL = resolvedURL
            }

            let mimeType = attributes["type"]?
                .split(separator: ";", maxSplits: 1)
                .first?
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isFeedType = [
                "application/rss+xml",
                "application/atom+xml",
                "application/rdf+xml"
            ].contains(mimeType)

            if relationships.contains("alternate"), isFeedType {
                let key = ProviderURLSupport.comparisonKey(for: resolvedURL)
                if seenFeedURLs.insert(key).inserted {
                    feedURLs.append(resolvedURL)
                }
            }
        }

        var metadataTitle: String?
        var openGraphURL: URL?
        for attributes in HTMLTagParser.tags(named: "meta", in: html) {
            let property = (attributes["property"] ?? attributes["name"] ?? "")
                .lowercased()
            let content = attributes["content"]

            if metadataTitle == nil,
               property == "og:title" || property == "twitter:title"
            {
                metadataTitle = ProviderTextSupport.cleanedTitle(content)
            }

            if openGraphURL == nil,
               property == "og:url",
               let url = ProviderURLSupport.resolvedURL(content, relativeTo: baseURL),
               ProviderURLSupport.isHTTPURL(url)
            {
                openGraphURL = url
            }
        }

        let title = metadataTitle
            ?? ProviderTextSupport.cleanedTitle(
                HTMLTagParser.firstElementText(named: "title", in: html)
            )

        return HTMLRSSDiscoveryResult(
            pageURL: pageURL,
            canonicalURL: canonicalURL ?? openGraphURL,
            title: title,
            feedURLs: feedURLs
        )
    }
}

private enum HTMLTagParser {
    static func tags(named name: String, in html: String) -> [[String: String]] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: #"<\#(escapedName)\b[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            return attributes(in: String(html[tagRange]))
        }
    }

    static func firstElementText(named name: String, in html: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: #"<\#(escapedName)\b[^>]*>(.*?)</\#(escapedName)\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let contentRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        return String(html[contentRange])
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][A-Za-z0-9_:.\-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return [:]
        }

        var attributes: [String: String] = [:]
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)

        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else {
                continue
            }

            let valueRange = [2, 3, 4]
                .lazy
                .compactMap { Range(match.range(at: $0), in: tag) }
                .first

            guard let valueRange else { continue }
            let name = tag[nameRange].lowercased()
            attributes[name] = ProviderTextSupport.decodeHTMLEntities(
                String(tag[valueRange])
            )
        }

        return attributes
    }
}
