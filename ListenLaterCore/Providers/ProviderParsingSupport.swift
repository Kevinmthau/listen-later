import Foundation

enum ProviderURLSupport {
    private static let ignoredQueryNames = Set([
        "fbclid", "gclid", "mc_cid", "mc_eid", "si"
    ])

    static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty,
              isPublicHost(host)
        else {
            return false
        }
        return true
    }

    static func isYouTubeHost(_ host: String?) -> Bool {
        guard let rawHost = host else { return false }
        let host = normalizedHost(rawHost)
        return host == "youtu.be"
            || host == "www.youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
    }

    static func resolvedURL(_ rawValue: String?, relativeTo baseURL: URL) -> URL? {
        guard let rawValue else { return nil }
        let decoded = ProviderTextSupport.decodeHTMLEntities(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        guard let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              isHTTPURL(url)
        else {
            return nil
        }
        return url
    }

    static func sameResource(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return comparisonKey(for: lhs) == comparisonKey(for: rhs)
    }

    static func sameHostAndPath(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: true),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: true)
        else {
            return false
        }

        return left.host?.lowercased() == right.host?.lowercased()
            && normalizedPath(left.path) == normalizedPath(right.path)
    }

    static func comparisonKey(for url: URL) -> String {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        components.path = normalizedPath(components.path)
        components.queryItems = components.queryItems?
            .filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !ignoredQueryNames.contains(name)
            }
            .sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }

        return components.string ?? url.absoluteString
    }

    static func inferredTitle(from url: URL) -> String {
        var value = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.deletingPathExtension().lastPathComponent

        value = value.replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(of: "-", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty {
            return url.host ?? "Audio"
        }

        return value
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var result = path
        while result.hasSuffix("/") && result.count > 1 {
            result.removeLast()
        }
        return result
    }

    private static func isPublicHost(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)

        guard host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".lan"),
              host != "home.arpa",
              !host.hasSuffix(".home.arpa")
        else {
            return false
        }

        if host.contains(":") {
            // Global unicast IPv6 addresses currently occupy 2000::/3.
            // Everything else includes loopback, link-local, unique-local,
            // multicast, mapped IPv4, documentation, or unspecified space.
            return host.first == "2" || host.first == "3"
        }

        let numericHost = host.allSatisfy { $0.isNumber || $0 == "." }
        guard numericHost else { return true }

        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              let octets = Optional(pieces.compactMap { UInt8($0) }),
              octets.count == 4
        else {
            // Reject legacy shorthand and integer forms such as 127.1 or
            // 2130706433, which network stacks may interpret as loopback.
            return false
        }

        let a = octets[0]
        let b = octets[1]
        let c = octets[2]

        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 198 && (18...19).contains(b) { return false }

        // Non-routable protocol and documentation networks.
        if a == 192 && b == 0 && c == 0 { return false }
        if a == 192 && b == 0 && c == 2 { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }

        return true
    }

    static func isIPAddressLiteral(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)
        return host.contains(":")
            || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    static func isPublicIPAddress(_ address: String) -> Bool {
        isIPAddressLiteral(address) && isPublicHost(address)
    }

    static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }
}

enum ProviderTextSupport {
    static func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " ")
        ]

        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"&#(?:x([0-9a-fA-F]+)|([0-9]+));"#
        ) else {
            return decoded
        }

        let fullRange = NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
        for match in regex.matches(in: decoded, range: fullRange).reversed() {
            let hexadecimal = Range(match.range(at: 1), in: decoded).map { String(decoded[$0]) }
            let decimal = Range(match.range(at: 2), in: decoded).map { String(decoded[$0]) }

            let scalarValue: UInt32?
            if let hexadecimal {
                scalarValue = UInt32(hexadecimal, radix: 16)
            } else if let decimal {
                scalarValue = UInt32(decimal, radix: 10)
            } else {
                scalarValue = nil
            }

            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue),
                  let range = Range(match.range, in: decoded)
            else {
                continue
            }
            decoded.replaceSubrange(range, with: String(Character(scalar)))
        }

        return decoded
    }

    static func normalizedTitle(_ value: String?) -> String {
        guard let value else { return "" }

        let decoded = decodeHTMLEntities(value)
        let withoutTags = decoded.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let folded = withoutTags.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        let alphanumeric = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }

        return String(alphanumeric)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func cleanedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let decoded = decodeHTMLEntities(value)
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}

enum ProviderDurationParser {
    static func podcastDuration(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }

        let pieces = value.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == value.split(separator: ":").count,
              (2...3).contains(pieces.count)
        else {
            return nil
        }

        if pieces.count == 2 {
            return pieces[0] * 60 + pieces[1]
        }
        return pieces[0] * 3_600 + pieces[1] * 60 + pieces[2]
    }

    /// Parses the ISO 8601 durations returned by YouTube's `contentDetails`.
    static func iso8601Duration(_ value: String?) -> TimeInterval? {
        guard let value, value.first == "P" else { return nil }

        let pattern = #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              match.range.location != NSNotFound,
              (1...4).contains(where: { match.range(at: $0).location != NSNotFound })
        else {
            return nil
        }

        func number(at index: Int) -> Double {
            guard let range = Range(match.range(at: index), in: value) else { return 0 }
            return Double(value[range]) ?? 0
        }

        return number(at: 1) * 86_400
            + number(at: 2) * 3_600
            + number(at: 3) * 60
            + number(at: 4)
    }
}

enum ProviderDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: value) {
            return date
        }
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: value) {
            return date
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }
}
