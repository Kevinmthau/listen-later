import Foundation

struct ApplePodcastsLink: Hashable, Sendable {
    let showID: String
    let episodeID: String?

    static func parse(_ url: URL) -> Self? {
        guard ProviderURLSupport.isHTTPURL(url),
              let rawHost = url.host
        else {
            return nil
        }
        let host = ProviderURLSupport.normalizedHost(rawHost)
        guard
              host == "podcasts.apple.com"
                || host == "itunes.apple.com"
                || host.hasSuffix(".itunes.apple.com")
        else {
            return nil
        }

        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"id(\d+)"#),
              let match = regex.firstMatch(
                  in: path,
                  range: NSRange(path.startIndex..<path.endIndex, in: path)
              ),
              let idRange = Range(match.range(at: 1), in: path)
        else {
            return nil
        }

        let showID = String(path[idRange])
        let episodeID = URLComponents(
            url: url,
            resolvingAgainstBaseURL: true
        )?
        .queryItems?
        .first(where: { $0.name.caseInsensitiveCompare("i") == .orderedSame })?
        .value
        .flatMap { value in
            value.allSatisfy(\.isNumber) ? value : nil
        }

        return Self(showID: showID, episodeID: episodeID)
    }
}
