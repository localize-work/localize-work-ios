import Foundation
import os

/// A project's published translations: downloaded from the localize.work
/// CDN, kept on the device, and looked up by key.
///
/// ```swift
/// Localize.configure(LocalizeConfiguration(projectSlug: "my-app", fallbackLocale: "en"))
/// let title = Localize.shared.string("nav.home")
/// ```
///
/// Every method can be called from any thread.
public final class Localize: Sendable {
    /// The version of this SDK.
    public static let sdkVersion = "0.1.0"

    /// Posted on the main thread when a newly downloaded release starts
    /// being used. The object is the `Localize` instance; `userInfo` holds
    /// the version under ``versionUserInfoKey``.
    public static let didUpdateNotification = Notification.Name("LocalizeWorkDidUpdate")

    /// The `userInfo` key of the release version (a `String` such as `"v12"`).
    public static let versionUserInfoKey = "version"

    // MARK: Shared instance

    /// The instance set up by ``configure(_:refresh:)``. Before that it has
    /// no project: lookups return bundled strings and `refresh()` throws
    /// ``LocalizeError/notConfigured``.
    public static var shared: Localize {
        sharedInstance.withLock { $0 } ?? unconfigured
    }

    /// Sets up ``shared``. Call it once, early in the app's launch.
    ///
    /// The release saved on the device is loaded before this returns, so
    /// lookups work at once. With `refresh` true (the default) the latest
    /// release is then downloaded in the background.
    @discardableResult
    public static func configure(_ configuration: LocalizeConfiguration, refresh: Bool = true) -> Localize {
        let instance = Localize(configuration: configuration)
        sharedInstance.withLock { $0 = instance }
        if refresh {
            Task {
                do {
                    try await instance.refresh()
                } catch {
                    log.error("localize.work refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return instance
    }

    private static let sharedInstance = Locked<Localize?>(nil)
    private static let unconfigured = Localize(configuration: LocalizeConfiguration(projectSlug: ""))
    private static let log = Logger(subsystem: "work.localize.sdk", category: "LocalizeWork")

    // MARK: Instance

    public let configuration: LocalizeConfiguration

    /// The locales a string is looked up in, most specific first.
    private let localeChain: [String]
    private let store: ReleaseStore?
    private let state: Locked<State>

    private struct State {
        /// The release lookups read.
        var active: Release?
        /// The release saved on the device. With the next-launch policy it
        /// can be newer than `active`.
        var saved: Release?
        var refresh: Task<LocalizeRefreshResult, Error>?
        var observers: [UUID: AsyncStream<String>.Continuation] = [:]
    }

    /// Creates an instance and loads the release saved on the device, if
    /// there is one. Nothing is downloaded until ``refresh()`` is called.
    public init(configuration: LocalizeConfiguration) {
        self.configuration = configuration
        localeChain = configuration.localeChain
        if configuration.projectSlug.isEmpty {
            store = nil
        } else {
            store = (configuration.cacheDirectory ?? ReleaseStore.defaultRoot()).map {
                ReleaseStore(root: $0, projectSlug: configuration.projectSlug, cdnBaseURL: configuration.cdnBaseURL)
            }
        }
        let saved = store?.load()
        state = Locked(State(active: saved, saved: saved))
    }

    /// The release version in use, such as `"v12"`. Nil until a release has
    /// been downloaded or loaded from the device.
    public var version: String? {
        state.withLock { $0.active?.version }
    }

    // MARK: Lookup

    /// The text for `key`.
    ///
    /// The release is searched in ``LocalizeConfiguration/localeChain``
    /// order. A key no locale has gives the app's bundled string, then
    /// `fallback`, then the key itself.
    ///
    /// - Parameters:
    ///   - key: The key, such as `"nav.home"`.
    ///   - arguments: Values for the string's `{{name}}` placeholders.
    ///   - count: The number a plural string is about. It selects the plural
    ///     form and fills `{{count}}`.
    ///   - namespace: The namespace to look in. Nil uses the default one.
    ///   - fallback: The text to return when neither the release nor the
    ///     app bundle has the key.
    public func string(
        _ key: String,
        _ arguments: LocalizeArguments = [:],
        count: Int? = nil,
        namespace: String? = nil,
        fallback: String? = nil
    ) -> String {
        let namespace = namespace ?? configuration.defaultNamespace
        let resolve: (String) -> String? = { name in
            if name == "count", let count { return String(count) }
            return arguments.value(named: name).map(LocalizeArguments.text)
        }
        if let release = state.withLock({ $0.active }) {
            for locale in localeChain {
                guard let file = release.files[FileKey(locale: locale, namespace: namespace)] else { continue }
                for name in KeyLookup.candidates(key: key, count: count, locale: locale) {
                    if let text = KeyLookup.string(in: file, key: name) {
                        return Interpolation.apply(text, resolve: resolve)
                    }
                }
            }
        }
        if let bundled = BundledStrings.string(
            key: key,
            namespace: namespace,
            bundle: configuration.bundle,
            arguments: arguments,
            count: count
        ) {
            return bundled
        }
        if let fallback { return Interpolation.apply(fallback, resolve: resolve) }
        return key
    }

    // MARK: Refresh

    /// Downloads the published release if it is not on the device yet.
    ///
    /// The release is used only once every file of it has arrived. If
    /// anything fails this throws a ``LocalizeError`` and the release that
    /// was in use stays in use. Calls made while a refresh is running wait
    /// for that refresh and share its result.
    @discardableResult
    public func refresh() async throws -> LocalizeRefreshResult {
        let task = state.withLock { state -> Task<LocalizeRefreshResult, Error> in
            if let running = state.refresh { return running }
            let task = Task { [self] in
                defer { self.state.withLock { $0.refresh = nil } }
                return try await performRefresh()
            }
            state.refresh = task
            return task
        }
        return try await task.value
    }

    private func performRefresh() async throws -> LocalizeRefreshResult {
        try validateConfiguration()
        let loader = ReleaseLoader(
            projectSlug: configuration.projectSlug,
            cdnBaseURL: configuration.cdnBaseURL,
            transport: configuration.transport,
            timeout: configuration.requestTimeout
        )
        // The pointer is read once. Every file below comes from the version
        // it named, whatever is published in the meantime.
        let version: String
        if let pinned = configuration.version {
            version = pinned
        } else {
            version = try await loader.latestVersion()
        }

        let needed = localeChain.flatMap { locale in
            configuration.namespaces.map { FileKey(locale: locale, namespace: $0) }
        }
        // Files of a version never change, so the ones already here for this
        // version are reused and only the rest are downloaded.
        let (active, saved) = state.withLock { ($0.active, $0.saved) }
        var files: [FileKey: [String: Node]] = [:]
        for known in [saved, active] {
            guard let known, known.version == version else { continue }
            for file in needed where files[file] == nil {
                files[file] = known.files[file]
            }
        }
        let missing = Set(needed).subtracting(files.keys)
        try await withThrowingTaskGroup(of: (FileKey, [String: Node]).self) { group in
            for file in missing {
                group.addTask { (file, try await loader.file(version: version, file: file)) }
            }
            for try await (file, contents) in group {
                files[file] = contents
            }
        }
        // Reached only with every file in hand.
        let release = Release(version: version, files: files)

        if saved.map({ $0.hasSameContents(as: release) }) != true {
            do {
                guard let store else { throw CocoaError(.fileNoSuchFile) }
                try store.save(release)
                state.withLock { $0.saved = release }
            } catch {
                // With the next-launch policy a release that is not saved
                // never takes effect, so that is a failure. Otherwise the
                // release is still used for this run.
                if configuration.updatePolicy == .nextLaunch {
                    throw LocalizeError.cacheWriteFailed(error.localizedDescription)
                }
                Self.log.error("localize.work could not save the release: \(error.localizedDescription, privacy: .public)")
            }
        }

        switch configuration.updatePolicy {
        case .immediately:
            let observers = state.withLock { state -> [AsyncStream<String>.Continuation]? in
                if let active = state.active, active.hasSameContents(as: release) { return nil }
                state.active = release
                return Array(state.observers.values)
            }
            guard let observers else { return .upToDate(version: version) }
            for observer in observers { observer.yield(version) }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Self.didUpdateNotification,
                    object: self,
                    userInfo: [Self.versionUserInfoKey: version]
                )
            }
            return .updated(version: version)
        case .nextLaunch:
            if let active, active.hasSameContents(as: release) { return .upToDate(version: version) }
            return .pendingNextLaunch(version: version)
        }
    }

    private func validateConfiguration() throws {
        guard !configuration.projectSlug.isEmpty else { throw LocalizeError.notConfigured }
        func check(_ value: String, _ name: String) throws {
            if value.isEmpty || value == "." || value == ".." {
                throw LocalizeError.invalidConfiguration("\(name) \"\(value)\" cannot be part of a URL")
            }
        }
        try check(configuration.projectSlug, "project slug")
        if configuration.namespaces.isEmpty {
            throw LocalizeError.invalidConfiguration("namespaces is empty")
        }
        try configuration.namespaces.forEach { try check($0, "namespace") }
        if localeChain.isEmpty {
            throw LocalizeError.invalidConfiguration("locale is empty")
        }
        try localeChain.forEach { try check($0, "locale") }
        if let version = configuration.version, !ReleaseJSON.isValidVersion(version) {
            throw LocalizeError.invalidConfiguration("version \"\(version)\" is not a release version such as \"v12\"")
        }
    }

    // MARK: Updates

    /// The versions of releases as they start being used, from now on. Each
    /// access gives a new stream; it ends when its consumer stops.
    ///
    /// ```swift
    /// for await _ in Localize.shared.updates {
    ///     // re-read the strings on screen
    /// }
    /// ```
    public var updates: AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.observers[id] = nil }
        }
        state.withLock { $0.observers[id] = continuation }
        return stream
    }
}
