import Foundation

/// What a transport returns for one request: the HTTP status and the body.
public struct LocalizeHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// How the SDK reaches the CDN. The default is ``URLSessionTransport``; tests
/// pass their own to answer requests without a network.
///
/// Every request is a plain `GET` of a public file. A transport returns the
/// response whatever its status, and throws only when no response arrived.
public protocol LocalizeTransport: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> LocalizeHTTPResponse
}

/// The default transport: unauthenticated `GET` requests on a private
/// `URLSession` that keeps no cookies, credentials or cache.
public struct URLSessionTransport: LocalizeTransport {
    /// The longest a single download may take in total, however slowly it
    /// trickles in. The per-request timeout only limits the wait between
    /// packets.
    static let resourceTimeout: TimeInterval = 120

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = resourceTimeout
        // Fixed values in place of what URLSession would send by default: the
        // app's name and system version, and the device's language list.
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Language": "*",
            "User-Agent": "localize-work-ios/\(Localize.sdkVersion)",
        ]
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func get(_ url: URL, timeout: TimeInterval) async throws -> LocalizeHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let (body, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return LocalizeHTTPResponse(statusCode: http.statusCode, body: body)
    }
}
