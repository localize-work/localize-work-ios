import Foundation

/// Downloads a release: the pointer, then the files of the version it names.
struct ReleaseLoader: Sendable {
    let projectSlug: String
    let cdnBaseURL: URL
    let transport: any LocalizeTransport
    let timeout: TimeInterval

    /// `{cdnBaseUrl}/{projectSlug}/latest.json`
    func pointerURL() throws -> URL {
        try url(path: [projectSlug], file: "latest.json")
    }

    /// `{cdnBaseUrl}/{projectSlug}/{version}/{locale}/{namespace}.json`
    func fileURL(version: String, file: FileKey) throws -> URL {
        try url(path: [projectSlug, version, file.locale], file: "\(Self.segment(file.namespace)).json")
    }

    /// The version `latest.json` names.
    func latestVersion() async throws -> String {
        let url = try pointerURL()
        let response = try await get(url)
        switch response.statusCode {
        case 200..<300:
            // A pointer that names no version is a configuration problem,
            // and asking again would only get the same answer.
            guard let version = ReleaseJSON.pointerVersion(from: response.body) else {
                throw LocalizeError.invalidPointer(url: url)
            }
            return version
        case 404:
            throw LocalizeError.projectNotPublished(url: url)
        default:
            throw LocalizeError.http(status: response.statusCode, url: url)
        }
    }

    /// One file of a version, or nil when the version does not have it.
    /// That is normal: regional variants publish only their overrides, and
    /// often none.
    func file(version: String, file: FileKey) async throws -> [String: Node]? {
        let url = try fileURL(version: version, file: file)
        let response = try await get(url)
        switch response.statusCode {
        case 200..<300:
            guard let contents = ReleaseJSON.file(from: response.body) else {
                throw LocalizeError.invalidFile(url: url)
            }
            return contents
        case 404:
            return nil
        default:
            throw LocalizeError.http(status: response.statusCode, url: url)
        }
    }

    private func get(_ url: URL) async throws -> LocalizeHTTPResponse {
        do {
            return try await transport.get(url, timeout: timeout)
        } catch let error as LocalizeError {
            throw error
        } catch {
            throw LocalizeError.network(url: url, message: error.localizedDescription)
        }
    }

    private func url(path: [String], file: String) throws -> URL {
        var base = cdnBaseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let text = ([base] + path.map(Self.segment) + [file]).joined(separator: "/")
        guard let url = URL(string: text) else {
            throw LocalizeError.invalidConfiguration("cannot build a URL from \(text)")
        }
        return url
    }

    /// One path segment, escaped as JavaScript's `encodeURIComponent` does,
    /// so both SDKs request the same URL.
    static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
}
