import Darwin
import Foundation

/// Small URLSession wrapper shared by the adapters. Passing a configured
/// URLSession makes URLProtocol-based tests possible without provider changes.
struct ProviderHTTPClient: @unchecked Sendable {
    let session: URLSession
    private let validateEndpoint: @Sendable (URL) async throws -> Void

    init(
        session: URLSession,
        validateEndpoint: @escaping @Sendable (URL) async throws -> Void = {
            try await ProviderEndpointValidator.validate($0)
        }
    ) {
        self.session = session
        self.validateEndpoint = validateEndpoint
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
        do {
            let (bytes, httpResponse) = try await responseFollowingRedirects(
                for: request
            )
            let responseURL = httpResponse.url ?? requestURL

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
            let (bytes, httpResponse) = try await responseFollowingRedirects(
                for: request
            )
            bytes.task.cancel()
            let responseURL = httpResponse.url ?? url
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

    /// Resolves and validates the redirect chain immediately before a remote
    /// endpoint is persisted for AVPlayer or AsyncImage consumption.
    func resolvedEndpointURL(
        for url: URL,
        timeout: TimeInterval = 12
    ) async throws -> URL {
        do {
            return try await headResponse(for: url, timeout: timeout).url ?? url
        } catch ProviderResolutionError.httpStatus {
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: timeout
            )
            request.httpMethod = "GET"
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.setValue("*/*", forHTTPHeaderField: "Accept")

            do {
                let (bytes, response) = try await responseFollowingRedirects(
                    for: request
                )
                bytes.task.cancel()
                let responseURL = response.url ?? url
                guard (200..<300).contains(response.statusCode) else {
                    throw ProviderResolutionError.httpStatus(
                        response.statusCode,
                        redacted(responseURL)
                    )
                }
                return responseURL
            } catch let error as ProviderResolutionError {
                throw error
            } catch {
                throw ProviderResolutionError.network(error.localizedDescription)
            }
        }
    }

    private func responseFollowingRedirects(
        for request: URLRequest,
        maximumRedirects: Int = 10
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var currentRequest = request

        for redirectCount in 0...maximumRedirects {
            guard let requestURL = currentRequest.url,
                  ProviderURLSupport.isHTTPURL(requestURL)
            else {
                throw ProviderResolutionError.invalidURL(
                    redacted(currentRequest.url ?? URL(fileURLWithPath: "/"))
                )
            }
            try await validateEndpoint(requestURL)

            let (bytes, response) = try await session.bytes(
                for: currentRequest,
                delegate: ProviderNoRedirectDelegate()
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderResolutionError.invalidHTTPResponse(
                    redacted(requestURL)
                )
            }

            guard [301, 302, 303, 307, 308].contains(httpResponse.statusCode),
                  let location = httpResponse.value(
                      forHTTPHeaderField: "Location"
                  )
            else {
                guard let responseURL = httpResponse.url,
                      ProviderURLSupport.isHTTPURL(responseURL)
                else {
                    throw ProviderResolutionError.invalidURL(
                        redacted(httpResponse.url ?? requestURL)
                    )
                }
                return (bytes, httpResponse)
            }
            bytes.task.cancel()

            guard redirectCount < maximumRedirects else {
                throw ProviderResolutionError.malformedResponse(
                    "The server returned too many redirects."
                )
            }
            guard let redirectURL = URL(
                string: location,
                relativeTo: requestURL
            )?.absoluteURL,
            ProviderURLSupport.isHTTPURL(redirectURL)
            else {
                throw ProviderResolutionError.invalidURL(
                    redacted(
                        URL(string: location, relativeTo: requestURL)?.absoluteURL
                            ?? requestURL
                    )
                )
            }

            var redirectedRequest = currentRequest
            redirectedRequest.url = redirectURL
            if httpResponse.statusCode == 303,
               currentRequest.httpMethod?.uppercased() != "HEAD"
            {
                redirectedRequest.httpMethod = "GET"
                redirectedRequest.httpBody = nil
                redirectedRequest.setValue(nil, forHTTPHeaderField: "Content-Length")
            }
            if requestURL.host?.caseInsensitiveCompare(redirectURL.host ?? "")
                != .orderedSame
            {
                redirectedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
                redirectedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            currentRequest = redirectedRequest
        }

        throw ProviderResolutionError.malformedResponse(
            "The server returned too many redirects."
        )
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

private final class ProviderNoRedirectDelegate:
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
        completionHandler(nil)
    }
}

enum ProviderEndpointValidator {
    private enum Resolution: Equatable, Sendable {
        case publicEndpoint
        case privateEndpoint
        case unresolved
        case timedOut
        case cancelled
    }

    private final class ResolutionRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Resolution, Never>?
        private var result: Resolution?

        func install(_ continuation: CheckedContinuation<Resolution, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(with result: Resolution) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    static func validate(
        _ url: URL,
        timeout: Duration = .seconds(5)
    ) async throws {
        guard ProviderURLSupport.isHTTPURL(url) else {
            throw ProviderResolutionError.invalidURL(url)
        }

        let race = ResolutionRace()
        let endpointResolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                Task.detached(priority: .userInitiated) {
                    race.finish(
                        with: ProviderEndpointValidator.resolution(for: url)
                    )
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    race.finish(with: .timedOut)
                }
            }
        } onCancel: {
            race.finish(with: .cancelled)
        }

        switch endpointResolution {
        case .publicEndpoint:
            return
        case .privateEndpoint:
            throw ProviderResolutionError.invalidURL(url)
        case .unresolved:
            throw ProviderResolutionError.network(
                "The host \(url.host ?? "") could not be resolved."
            )
        case .timedOut:
            throw ProviderResolutionError.network(
                "Resolving \(url.host ?? "this host") timed out."
            )
        case .cancelled:
            throw CancellationError()
        }
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
