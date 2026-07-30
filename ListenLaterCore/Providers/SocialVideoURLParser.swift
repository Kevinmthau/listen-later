import Foundation

enum SocialVideoPlatform: String, Codable, Sendable {
    case instagram
    case x

    var displayName: String {
        switch self {
        case .instagram: "Instagram"
        case .x: "X"
        }
    }
}

struct SocialVideoURL: Equatable, Sendable {
    let platform: SocialVideoPlatform
    let mediaID: String
    let creatorName: String?
}

enum SocialVideoURLParser {
    private static let xHosts = Set(["twitter.com", "x.com"])
    private static let instagramHosts = Set(["instagram.com", "instagr.am"])
    private static let instagramKinds = Set(["p", "reel", "tv"])

    static func parse(_ url: URL) -> SocialVideoURL? {
        guard url.scheme?.lowercased() == "https",
              let rawHost = url.host
        else {
            return nil
        }

        let host = normalizedHost(rawHost)
        let components = url.pathComponents.filter { $0 != "/" }

        if xHosts.contains(host),
           let statusIndex = components.firstIndex(of: "status"),
           components.indices.contains(statusIndex + 1)
        {
            let mediaID = components[statusIndex + 1]
            guard !mediaID.isEmpty, mediaID.allSatisfy(\.isNumber) else {
                return nil
            }
            let username = statusIndex > 0 ? components[statusIndex - 1] : ""
            let creatorName =
                username.isEmpty || username.caseInsensitiveCompare("i") == .orderedSame
                ? nil
                : "@\(username)"
            return SocialVideoURL(
                platform: .x,
                mediaID: mediaID,
                creatorName: creatorName
            )
        }

        if instagramHosts.contains(host) {
            for (index, component) in components.enumerated()
            where instagramKinds.contains(component.lowercased())
                && components.indices.contains(index + 1)
            {
                let mediaID = components[index + 1]
                guard !mediaID.isEmpty,
                      mediaID.allSatisfy({
                          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                      })
                else {
                    return nil
                }
                return SocialVideoURL(
                    platform: .instagram,
                    mediaID: mediaID,
                    creatorName: nil
                )
            }
        }

        return nil
    }

    static func isSupported(_ url: URL) -> Bool {
        parse(url) != nil
    }

    static func canonicalURL(for url: URL) -> URL? {
        guard let parsed = parse(url),
              var components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )
        else {
            return nil
        }
        components.scheme = "https"
        components.host = parsed.platform == .x ? "x.com" : "www.instagram.com"
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        return host
    }
}

enum SocialVideoPlaybackURL {
    private static let fallbackLifetime: TimeInterval = 4 * 60
    private static let safetyWindow: TimeInterval = 30

    static func expirationDate(
        for url: URL,
        now: Date = Date()
    ) -> Date {
        let fallback = now.addingTimeInterval(fallbackLifetime)
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return fallback
        }

        let candidates = ["Expires", "expires", "exp", "e"].compactMap { name in
            components.queryItems?
                .first(where: { $0.name == name })?
                .value
        }
        .compactMap(TimeInterval.init)
        .compactMap { value -> Date? in
            if value > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: value / 1_000)
            }
            if value > 1_000_000_000 {
                return Date(timeIntervalSince1970: value)
            }
            return nil
        }

        guard let upstreamExpiration = candidates.min() else {
            return fallback
        }
        let safeExpiration = upstreamExpiration.addingTimeInterval(-safetyWindow)
        return max(now, min(fallback, safeExpiration))
    }
}
