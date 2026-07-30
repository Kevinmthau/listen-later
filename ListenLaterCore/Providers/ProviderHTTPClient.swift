import Darwin
import Foundation

/// Small URLSession wrapper shared by the adapters. Passing a configured
/// URLSession makes URLProtocol-based tests possible without provider changes.
struct ProviderHTTPClient: @unchecked Sendable {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = request.url,
              ProviderURLSupport.isHTTPURL(requestURL)
        else {
            throw ProviderResolutionError.invalidURL(
                request.url ?? URL(fileURLWithPath: "/")
            )
        }
        try await ProviderEndpointValidator.validate(requestURL)

        do {
            let delegate = ProviderRedirectDelegate()
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: delegate
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderResolutionError.invalidHTTPResponse(
                    redacted(requestURL)
                )
            }
            guard let responseURL = httpResponse.url,
                  ProviderURLSupport.isHTTPURL(responseURL)
            else {
                throw ProviderResolutionError.invalidURL(
                    redacted(httpResponse.url ?? requestURL)
                )
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ProviderResolutionError.httpStatus(
                    httpResponse.statusCode,
                    redacted(responseURL)
                )
            }

            let declaredLength = httpResponse.expectedContentLength
            if declaredLength > Int64(maximumBytes) {
                throw ProviderResolutionError.responseTooLarge(
                    redacted(responseURL),
                    maximumBytes: maximumBytes
                )
            }

            var data = Data()
            data.reserveCapacity(min(maximumBytes, 64 * 1_024))
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw ProviderResolutionError.responseTooLarge(
                        redacted(responseURL),
                        maximumBytes: maximumBytes
                    )
                }
                data.append(byte)
            }

            return (data, httpResponse)
        } catch let error as ProviderResolutionError {
            throw error
        } catch {
            throw ProviderResolutionError.network(error.localizedDescription)
        }
    }

    func headResponse(for url: URL, timeout: TimeInterval = 12) async throws -> HTTPURLResponse {
        guard ProviderURLSupport.isHTTPURL(url) else {
            throw ProviderResolutionError.invalidURL(redacted(url))
        }
        try await ProviderEndpointValidator.validate(url)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "HEAD"
        request.setValue(
            "audio/*, application/rss+xml, application/atom+xml, text/html;q=0.8, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )

        do {
            let (_, response) = try await session.data(
                for: request,
                delegate: ProviderRedirectDelegate()
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderResolutionError.invalidHTTPResponse(redacted(url))
            }
            guard let responseURL = httpResponse.url,
                  ProviderURLSupport.isHTTPURL(responseURL)
            else {
                throw ProviderResolutionError.invalidURL(
                    redacted(httpResponse.url ?? url)
                )
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ProviderResolutionError.httpStatus(
                    httpResponse.statusCode,
                    redacted(responseURL)
                )
            }
            return httpResponse
        } catch let error as ProviderResolutionError {
            throw error
        } catch {
            throw ProviderResolutionError.network(error.localizedDescription)
        }
    }

    private func redacted(_ url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        components.fragment = nil
        components.queryItems = components.queryItems?.map { item in
            if ["key", "api_key", "apikey", "access_token"].contains(item.name.lowercased()) {
                return URLQueryItem(name: item.name, value: "REDACTED")
            }
            return item
        }
        return components.url ?? url
    }
}

private final class ProviderRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              ProviderURLSupport.isHTTPURL(url),
              ProviderEndpointValidator.isPubliclyResolvable(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum ProviderEndpointValidator {
    private enum Resolution: Equatable, Sendable {
        case publicEndpoint
        case privateEndpoint
        case unresolved
    }

    static func validate(_ url: URL) async throws {
        let task = Task<Resolution, Never>.detached(priority: .userInitiated) {
            ProviderEndpointValidator.resolution(for: url)
        }
        let endpointResolution = await task.value

        switch endpointResolution {
        case .publicEndpoint:
            return
        case .privateEndpoint:
            throw ProviderResolutionError.invalidURL(url)
        case .unresolved:
            throw ProviderResolutionError.network(
                "The host \(url.host ?? "") could not be resolved."
            )
        }
    }

    static func isPubliclyResolvable(_ url: URL) -> Bool {
        resolution(for: url) == .publicEndpoint
    }

    private static func resolution(for url: URL) -> Resolution {
        guard let rawHost = url.host else { return .unresolved }
        let host = ProviderURLSupport.normalizedHost(rawHost)

        if ProviderURLSupport.isIPAddressLiteral(host) {
            return ProviderURLSupport.isPublicIPAddress(host)
                ? .publicEndpoint
                : .privateEndpoint
        }

        let addresses = resolvedAddresses(for: host)
        guard !addresses.isEmpty else { return .unresolved }
        return addresses.allSatisfy(ProviderURLSupport.isPublicIPAddress)
            ? .publicEndpoint
            : .privateEndpoint
    }

    private static func resolvedAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0,
              let first = result
        else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = buffer.withUnsafeMutableBufferPointer { output in
                getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    output.baseAddress,
                    socklen_t(output.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            if status == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = current.pointee.ai_next
        }
        return Array(Set(addresses))
    }
}
