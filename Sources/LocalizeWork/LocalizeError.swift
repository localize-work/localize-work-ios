import Foundation

/// Why a refresh did not complete. Whatever the reason, the release that was
/// in use stays in use.
public enum LocalizeError: Error, Sendable, Equatable {
    /// ``Localize/shared`` was used before ``Localize/configure(_:refresh:)``.
    case notConfigured
    /// The configuration cannot produce a valid request. The text says which
    /// part.
    case invalidConfiguration(String)
    /// `latest.json` does not exist: nothing has been published for the
    /// project yet, or the project slug is wrong.
    case projectNotPublished(url: URL)
    /// `latest.json` did not name a release version such as `v12`.
    case invalidPointer(url: URL)
    /// The server answered with a status that is neither success nor 404.
    case http(status: Int, url: URL)
    /// No response arrived: offline, timed out, connection lost.
    case network(url: URL, message: String)
    /// A file arrived but is not the JSON object a published file is.
    case invalidFile(url: URL)
    /// A downloaded release that waits for the next launch could not be
    /// written to the device.
    case cacheWriteFailed(String)
    /// A later ``Localize/configure(_:refresh:)`` call replaced this
    /// instance while its refresh was running. The refresh is dropped, and
    /// however far it got, this is what its caller hears.
    case replaced

    /// Whether trying again later can succeed without changing anything.
    /// True for server errors and network failures; false for everything that
    /// points at the configuration or the published content.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status >= 500
        case .network, .cacheWriteFailed: return true
        case .notConfigured, .invalidConfiguration, .projectNotPublished, .invalidPointer, .invalidFile, .replaced:
            return false
        }
    }
}

extension LocalizeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Localize.configure(_:) has not been called."
        case .invalidConfiguration(let reason):
            return "Invalid localize.work configuration: \(reason)"
        case .projectNotPublished(let url):
            return "Nothing is published at \(url.absoluteString). Publish the project, or check the project slug."
        case .invalidPointer(let url):
            return "Invalid latest release pointer at \(url.absoluteString)."
        case .http(let status, let url):
            return "Loading \(url.absoluteString) failed with HTTP \(status)."
        case .network(let url, let message):
            return "Loading \(url.absoluteString) failed: \(message)"
        case .invalidFile(let url):
            return "\(url.absoluteString) is not a JSON object."
        case .cacheWriteFailed(let reason):
            return "The downloaded release could not be saved: \(reason)"
        case .replaced:
            return "This instance was replaced by a later Localize.configure(_:) call."
        }
    }
}

/// What a successful refresh did.
public enum LocalizeRefreshResult: Sendable, Equatable {
    /// The release in use is already the published one, and lookups read
    /// what they read before.
    case upToDate(version: String)
    /// Lookups read other texts now: redraw. A newly downloaded release is
    /// in use; or the one this run started with is, which lacked files for
    /// the language or could not be read from the device until now. The
    /// version is the one lookups read. With
    /// ``LocalizeUpdatePolicy/nextLaunch`` a newer release may have been
    /// saved for the next launch by the same refresh; this result does not
    /// mention it, and the next refresh reports it as `pendingNextLaunch`.
    case updated(version: String)
    /// A newly downloaded release is saved and takes effect at the next
    /// launch, and lookups read what they read before. Only with
    /// ``LocalizeUpdatePolicy/nextLaunch``.
    case pendingNextLaunch(version: String)
}
