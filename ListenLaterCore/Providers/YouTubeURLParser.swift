import Foundation

struct YouTubeURLParser: Sendable {
    static func isYouTubeURL(_ url: URL) -> Bool {
        ProviderURLSupport.isHTTPURL(url)
            && ProviderURLSupport.isYouTubeHost(url.host)
    }

    static func videoID(from url: URL) -> String? {
        videoID(from: url, recursionDepth: 0)
    }

    static func canonicalURL(for videoID: String) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    static func isValidVideoID(_ candidate: String) -> Bool {
        let bytes = candidate.utf8
        guard bytes.count == 11 else { return false }
        return bytes.allSatisfy { byte in
            (65...90).contains(byte)
                || (97...122).contains(byte)
                || (48...57).contains(byte)
                || byte == 95
                || byte == 45
        }
    }

    private static func videoID(from url: URL, recursionDepth: Int) -> String? {
        guard recursionDepth <= 2,
              isYouTubeURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let rawHost = components.host
        else {
            return nil
        }
        let host = ProviderURLSupport.normalizedHost(rawHost)

        let pathComponents = components.path
            .split(separator: "/")
            .map(String.init)

        if host == "youtu.be" || host == "www.youtu.be" {
            return pathComponents.first.flatMap(validated)
        }

        if let queryVideoID = components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("v") == .orderedSame })?
            .value
            .flatMap(validated)
        {
            return queryVideoID
        }

        if pathComponents.count >= 2 {
            let route = pathComponents[0].lowercased()
            if ["embed", "shorts", "live", "v"].contains(route),
               let videoID = validated(pathComponents[1])
            {
                return videoID
            }
        }

        let route = pathComponents.first?.lowercased()
        if route == "attribution_link" || route == "redirect" {
            let nestedValue = components.queryItems?
                .first(where: {
                    ["u", "q", "url"].contains($0.name.lowercased())
                })?
                .value

            if let nestedURL = nestedYouTubeURL(from: nestedValue, baseURL: url) {
                return videoID(from: nestedURL, recursionDepth: recursionDepth + 1)
            }
        }

        if let fragment = components.fragment,
           let fragmentComponents = URLComponents(string: "https://youtube.invalid/?\(fragment)"),
           let fragmentID = fragmentComponents.queryItems?
               .first(where: { $0.name.caseInsensitiveCompare("v") == .orderedSame })?
               .value
               .flatMap(validated)
        {
            return fragmentID
        }

        return nil
    }

    private static func nestedYouTubeURL(from value: String?, baseURL: URL) -> URL? {
        guard let value = value?.removingPercentEncoding ?? value,
              !value.isEmpty
        else {
            return nil
        }

        if value.hasPrefix("/") {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.youtube.com"

            guard let relative = URL(string: value, relativeTo: components.url)?.absoluteURL,
                  isYouTubeURL(relative)
            else {
                return nil
            }
            return relative
        }

        guard let nestedURL = URL(string: value),
              isYouTubeURL(nestedURL)
        else {
            return nil
        }
        return nestedURL
    }

    private static func validated(_ candidate: String) -> String? {
        let cleanCandidate = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidVideoID(cleanCandidate) ? cleanCandidate : nil
    }
}
