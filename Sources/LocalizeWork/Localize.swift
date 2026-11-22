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
        // The instance being replaced may still be downloading. From here on
        // it saves nothing, so it cannot write its release over the new
        // instance's, and the new instance reads the device after that point.
        commitLock.withLock { _ in
            sharedInstance.withLock { $0 }?.retired.withLock { $0 = true }
        }
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

    /// Puts ``shared`` back to its state before `configure`. For tests.
    static func resetShared() {
        commitLock.withLock { _ in
            sharedInstance.withLock { shared in
                shared?.retired.withLock { $0 = true }
                shared = nil
            }
        }
    }

    private static let sharedInstance = Locked<Localize?>(nil)
    /// Held while a release is saved, and while an instance is retired, so
    /// an instance that was replaced never saves after its replacement began.
    private static let commitLock = Locked<Void>(())
    private static let unconfigured = Localize(configuration: LocalizeConfiguration(projectSlug: ""))
    private static let log = Logger(subsystem: "work.localize.sdk", category: "LocalizeWork")

    // MARK: Instance

    public let configuration: LocalizeConfiguration

    /// The locales a string is looked up in, most specific first.
    private let localeChain: [String]
    private let store: ReleaseStore?
    private let state: Locked<State>

    /// Set when a later `configure` call replaced this instance.
    private let retired = Locked(false)

    private struct State {
        /// The release lookups read. It always holds every file the locale
        /// chain and the namespaces need.
        var active: Release?
        /// The release saved on the device. With the next-launch policy it
        /// can be newer than `active`; after a change of language it can
        /// lack files, and is then not in use until they are downloaded.
        var saved: Release?
        /// The version of the release this launch found on the device but
        /// could not use, because it lacked files for the current language.
        var incompleteAtStart: String?
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
        // A saved release of another version than the pinned one is not the
        // release this configuration asks for.
        let saved = store?.load().flatMap { release in
            configuration.version == nil || release.version == configuration.version ? release : nil
        }
        // A release is used whole or not at all. After a change of language
        // the saved one lacks the new language's files: until they arrive the
        // app's bundled strings, which are in that language, are the better text.
        let needed = Self.neededFiles(localeChain, configuration.namespaces)
        let active = saved.flatMap { $0.holds(needed) ? $0 : nil }
        state = Locked(State(
            active: active,
            saved: saved,
            incompleteAtStart: active == nil ? saved?.version : nil
        ))
    }

    private static func neededFiles(_ localeChain: [String], _ namespaces: [String]) -> [FileKey] {
        localeChain.flatMap { locale in namespaces.map { FileKey(locale: locale, namespace: $0) } }
    }

    deinit {
        // End the streams, or a consumer would wait on them forever.
        let observers = state.withLock { Array($0.observers.values) }
        for observer in observers { observer.finish() }
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
            // No locale has the form the count asks for, nor the plain key.
            // Before giving up on the release, take a language's general form.
            if count != nil {
                let other = "\(key)_\(PluralCategory.other.rawValue)"
                for locale in localeChain {
                    guard let file = release.files[FileKey(locale: locale, namespace: namespace)] else { continue }
                    if let text = KeyLookup.string(in: file, key: other) {
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
        if retired.withLock({ $0 }) { throw LocalizeError.replaced }
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

        let needed = Self.neededFiles(localeChain, configuration.namespaces)
        // Files of a version never change, so the ones already here for this
        // version are reused and only the rest are downloaded.
        let (active, saved, incompleteAtStart) = state.withLock { ($0.active, $0.saved, $0.incompleteAtStart) }
        var files: [FileKey: [String: Node]] = [:]
        for known in [saved, active] {
            guard let known, known.version == version else { continue }
            for file in needed where files[file] == nil {
                files[file] = known.files[file]
            }
        }
        let heldNothing = files.isEmpty
        let missing = Set(needed).subtracting(files.keys)
        var found = false
        try await withThrowingTaskGroup(of: (FileKey, [String: Node]?).self) { group in
            for file in missing {
                group.addTask { (file, try await loader.file(version: version, file: file)) }
            }
            for try await (file, contents) in group {
                if contents != nil { found = true }
                // A file the version does not have is an empty file.
                files[file] = contents ?? [:]
            }
        }
        if configuration.version != nil, heldNothing, !found, let first = needed.first {
            // Most likely the pinned release is not published yet. Saving it
            // as empty would hide it for good once it does exist.
            throw LocalizeError.http(status: 404, url: try loader.fileURL(version: version, file: first))
        }
        // Reached only with every file in hand.
        let release = Release(version: version, files: files)

        if saved.map({ $0.hasSameContents(as: release) }) != true {
            do {
                // An instance that `configure` has replaced must not write
                // its release over the one its replacement saves.
                try Self.commitLock.withLock { _ in
                    if retired.withLock({ $0 }) { throw LocalizeError.replaced }
                    guard let store else { throw CocoaError(.fileNoSuchFile) }
                    try store.save(release)
                }
                state.withLock { $0.saved = release }
            } catch LocalizeError.replaced {
                throw LocalizeError.replaced
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
            return await use(release) ? .updated(version: version) : .upToDate(version: version)
        case .nextLaunch:
            if let active, active.hasSameContents(as: release) { return .upToDate(version: version) }
            // The release this launch found on the device was not in use
            // only because it lacked files for the current language. With
            // them it is the release the launch started from, so it is used
            // now: nothing the app has shown from a release changes.
            if active == nil, incompleteAtStart == version {
                return await use(release) ? .updated(version: version) : .upToDate(version: version)
            }
            return .pendingNextLaunch(version: version)
        }
    }

    /// Makes `release` the one lookups read and announces it. False when it
    /// is what they read already.
    private func use(_ release: Release) async -> Bool {
        let observers = state.withLock { state -> [AsyncStream<String>.Continuation]? in
            if let active = state.active, active.hasSameContents(as: release) { return nil }
            state.active = release
            return Array(state.observers.values)
        }
        guard let observers else { return false }
        for observer in observers { observer.yield(release.version) }
        let version = release.version
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.didUpdateNotification,
                object: self,
                userInfo: [Self.versionUserInfoKey: version]
            )
        }
        return true
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
