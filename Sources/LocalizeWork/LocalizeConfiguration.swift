import Foundation

/// When a newly downloaded release starts being used.
public enum LocalizeUpdatePolicy: Sendable, Equatable {
    /// As soon as the whole release is downloaded. Strings can change while
    /// the app is running; observe ``Localize/updates`` or
    /// ``Localize/didUpdateNotification`` to re-read them.
    case immediately
    /// At the next launch. The download is saved, and the strings of a
    /// running app never change under it.
    case nextLaunch
}

/// How the SDK finds, loads and applies a project's published translations.
public struct LocalizeConfiguration: Sendable {
    public static let defaultCDNBaseURL = URL(string: "https://cdn.localize.work")!

    /// The project's slug, as in `https://cdn.localize.work/{projectSlug}/latest.json`.
    public var projectSlug: String

    /// The language to show, as a BCP 47 code such as `en`, `et` or `en-FI`.
    public var locale: String {
        didSet { locale = LocaleCode.canonical(locale) }
    }

    /// Where a string is looked up when ``locale`` does not have it. Usually
    /// the project's source language.
    public var fallbackLocale: String? {
        didSet { fallbackLocale = fallbackLocale.map(LocaleCode.canonical) }
    }

    /// The namespaces to download.
    public var namespaces: [String]

    /// The namespace a lookup uses when it does not name one.
    public var defaultNamespace: String

    /// A release version such as `"v12"` to stay on. Nil follows the latest
    /// published release.
    public var version: String?

    /// When a downloaded release starts being used.
    public var updatePolicy: LocalizeUpdatePolicy

    /// Where published files are served from.
    public var cdnBaseURL: URL

    /// How long a request may wait for data before it fails, in seconds.
    public var requestTimeout: TimeInterval

    /// The bundle whose string tables supply a string the release lacks.
    public var bundle: Bundle

    /// How requests are made. Replace it in tests.
    public var transport: any LocalizeTransport

    /// Where downloaded releases are kept. Nil uses a folder of its own in
    /// the app's Application Support directory (Caches on tvOS).
    public var cacheDirectory: URL?

    /// - Parameters:
    ///   - projectSlug: The project's slug.
    ///   - locale: The language to show. Nil uses the first of the device's
    ///     preferred languages.
    ///   - fallbackLocale: The language to fall back to, usually the
    ///     project's source language.
    ///   - namespaces: The namespaces to download.
    ///   - defaultNamespace: The namespace of a lookup that names none. Nil
    ///     uses the first of `namespaces`.
    ///   - version: A release version to stay on, or nil for the latest.
    ///   - updatePolicy: When a downloaded release starts being used.
    public init(
        projectSlug: String,
        locale: String? = nil,
        fallbackLocale: String? = nil,
        namespaces: [String] = ["translation"],
        defaultNamespace: String? = nil,
        version: String? = nil,
        updatePolicy: LocalizeUpdatePolicy = .immediately,
        cdnBaseURL: URL = LocalizeConfiguration.defaultCDNBaseURL,
        requestTimeout: TimeInterval = 15,
        bundle: Bundle = .main,
        transport: any LocalizeTransport = URLSessionTransport(),
        cacheDirectory: URL? = nil
    ) {
        self.projectSlug = projectSlug
        self.locale = LocaleCode.canonical(locale ?? Locale.preferredLanguages.first ?? "en")
        self.fallbackLocale = fallbackLocale.map(LocaleCode.canonical)
        self.namespaces = namespaces
        self.defaultNamespace = defaultNamespace ?? namespaces.first ?? "translation"
        self.version = version
        self.updatePolicy = updatePolicy
        self.cdnBaseURL = cdnBaseURL
        self.requestTimeout = requestTimeout
        self.bundle = bundle
        self.transport = transport
        self.cacheDirectory = cacheDirectory
    }

    /// The locales a string is looked up in, most specific first. For
    /// `en-FI` with fallback `et`: `en-FI`, `en`, `et`. Every namespace is
    /// downloaded for each of them.
    public var localeChain: [String] {
        LocaleCode.chain(locale: locale, fallback: fallbackLocale)
    }
}
