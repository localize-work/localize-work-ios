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
        // Retiring, reading the device and taking the old instance's place
        // are one step under the lock that saves take: of two calls at the
        // same time, the second retires the first one's instance.
        let instance = commitLock.withLock { _ -> Localize in
            let previous = sharedInstance.withLock { $0 }
            previous?.retired.withLock { $0 = true }
            let instance = Localize(configuration: configuration, continuing: previous)
            // A view listens to `Localize.shared.updates` once, for as long
            // as it is on screen. Its stream goes on with the new instance.
            instance.takeOverStreams(of: previous ?? unconfigured)
            sharedInstance.withLock { $0 = instance }
            return instance
        }
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
        /// The release this run of the app reads: `active`, or the one it
        /// started from that still lacks files for the current language.
        /// A refresh first makes it whole from its own version. With the
        /// next-launch policy it is the only release this run shows; nil
        /// then means the run started with none and shows bundled strings.
        var held: Release?
        var refresh: Task<LocalizeRefreshResult, Error>?
        /// The streams that hear of this instance's releases.
        var streams = UpdateStreams()
    }

    /// Creates an instance and loads the release saved on the device, if
    /// there is one. Nothing is downloaded until ``refresh()`` is called.
    public convenience init(configuration: LocalizeConfiguration) {
        self.init(configuration: configuration, continuing: nil)
    }

    /// - Parameter previous: The instance this one takes the place of while
    ///   the app keeps running, as when the language is changed.
    private init(configuration: LocalizeConfiguration, continuing previous: Localize?) {
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
        let matchesPin: (Release) -> Bool = { release in
            configuration.version == nil || release.version == configuration.version
        }
        let saved = store?.load().flatMap { matchesPin($0) ? $0 : nil }
        // An instance that takes over from another one for the same project
        // (a change of language) is still the same run of the app, and goes
        // on from the release that one held.
        var started = saved
        if let previous, let store, let theirs = previous.store,
           theirs.directory == store.directory, theirs.source == store.source {
            let held = previous.state.withLock({ $0.held }).flatMap { matchesPin($0) ? $0 : nil }
            switch configuration.updatePolicy {
            case .nextLaunch:
                // The release a run shows is decided when the app starts, so
                // it is what that instance started with, not what was saved
                // meanwhile. That holds for a run that started with nothing,
                // too: it keeps showing bundled strings.
                started = held
            case .immediately:
                // The newest release is read as soon as it is here, and the
                // saved one is that. When a release could not be saved it is
                // in use from memory only, and is not dropped for that.
                started = saved ?? held
            }
        }
        // A release is used whole or not at all. After a change of language
        // the saved one lacks the new language's files: until they arrive the
        // app's bundled strings, which are in that language, are the better text.
        let needed = Self.neededFiles(localeChain, configuration.namespaces)
        let active = started.flatMap { $0.holds(needed) ? $0 : nil }
        state = Locked(State(active: active, saved: saved, held: started))
    }

    private static func neededFiles(_ localeChain: [String], _ namespaces: [String]) -> [FileKey] {
        localeChain.flatMap { locale in namespaces.map { FileKey(locale: locale, namespace: $0) } }
    }

    /// Takes the streams `other` has handed out, which from now on hear of
    /// this instance's releases. `other` is left with none.
    private func takeOverStreams(of other: Localize) {
        let theirs = other.state.withLock { state -> UpdateStreams in
            let streams = state.streams
            state.streams = UpdateStreams()
            return streams
        }
        state.withLock { $0.streams = theirs }
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
        let needed = Self.neededFiles(localeChain, configuration.namespaces)
        // First the release this run already reads. After a change of
        // language it lacks the new language's files; they come from that
        // same version, whatever is published now and whether or not the
        // pointer or a newer release can be reached.
        let completedHeld = await completeHeldRelease(needed, loader)

        // The pointer is read once. Every file below comes from the version
        // it named, whatever is published in the meantime. A version the
        // pointer (or the pin) names is there, so a file it does not have is
        // an empty file, and the strings of that locale come from the next
        // one in the chain. `completed` cannot take that for granted of the
        // release it is given.
        let version: String
        if let pinned = configuration.version {
            version = pinned
        } else {
            version = try await loader.latestVersion()
        }

        // Files of a version never change, so every file already here for
        // this version is kept, also those of a language the app used
        // earlier, and only the rest are downloaded.
        let (saved, held) = state.withLock { ($0.saved, $0.held) }
        var files: [FileKey: [String: Node]] = [:]
        for known in [saved, held] {
            guard let known, known.version == version else { continue }
            files.merge(known.files) { first, _ in first }
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
                try save(release)
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
            let changed = await use(release)
            return changed || completedHeld ? .updated(version: version) : .upToDate(version: version)
        case .nextLaunch:
            // The published release is used in this run only when it is the
            // version the run started with: files of that version are added
            // (nothing the app has shown changes). Any other version waits
            // for the next launch, and a run that started with no release
            // keeps showing bundled strings.
            guard let held, held.version == version else { return .pendingNextLaunch(version: version) }
            let changed = await use(held.adding(release.files))
            return changed || completedHeld ? .updated(version: version) : .upToDate(version: version)
        }
    }

    /// Saves `release` as the one on the device.
    private func save(_ release: Release) throws {
        // An instance that `configure` has replaced must not write its
        // release over the one its replacement saves.
        let written = try Self.commitLock.withLock { _ -> Release in
            if retired.withLock({ $0 }) { throw LocalizeError.replaced }
            guard let store else { throw CocoaError(.fileNoSuchFile) }
            // Another instance of the project, one in another language say,
            // may have saved files of this version since this one read the
            // device. Files of a version never change, so they are kept.
            var whole = release
            if let there = store.load(), there.version == release.version {
                whole = release.adding(there.files)
            }
            try store.save(whole)
            return whole
        }
        state.withLock { $0.saved = written }
    }

    /// Makes the release this run reads whole for the current language, from
    /// its own version, and puts it in use. True when that changed what
    /// lookups read. Nothing is thrown: when the files cannot be had now, the
    /// app shows bundled strings and the next refresh tries again.
    private func completeHeldRelease(_ needed: [FileKey], _ loader: ReleaseLoader) async -> Bool {
        let (active, held, saved) = state.withLock { ($0.active, $0.held, $0.saved) }
        guard active == nil, let held, let whole = await completed(held, needed, loader) else { return false }
        // The copy on the device gets the files too while it is this
        // version, so the next launch starts whole. A failure only costs
        // that; the files are in use from memory.
        if let saved, saved.version == whole.version {
            try? save(saved.adding(whole.files))
        }
        return await use(whole)
    }

    /// `release` with the files of `needed` it lacks, fetched from its own
    /// version; nil when it cannot be made whole.
    ///
    /// When none of the missing files exists, the release may be gone from
    /// the CDN, and reading it with empty files would show its fallback
    /// language in place of the app's bundled strings. It is completed all
    /// the same when every locale that lacks files is a regional form of a
    /// language the release has texts for: a regional locale without
    /// overrides of its own has no file, and that is normal.
    private func completed(_ release: Release, _ needed: [FileKey], _ loader: ReleaseLoader) async -> Release? {
        let missing = needed.filter { release.files[$0] == nil }
        var files: [FileKey: [String: Node]] = [:]
        var found = false
        for file in missing {
            do {
                if let contents = try await loader.file(version: release.version, file: file) {
                    found = true
                    files[file] = contents
                } else {
                    // A file the version does not have is an empty file.
                    files[file] = [:]
                }
            } catch {
                // The release stays as it is; the next refresh tries again.
                return nil
            }
        }
        if !found, !Set(missing.map(\.locale)).allSatisfy({ release.hasTexts(inABaseOf: $0) }) { return nil }
        return release.adding(files)
    }

    /// Makes `release` the one lookups read and announces it. False when it
    /// is what they read already.
    private func use(_ release: Release) async -> Bool {
        let streams = state.withLock { state -> UpdateStreams? in
            if let active = state.active, active.hasSameContents(as: release) { return nil }
            state.active = release
            state.held = release
            return state.streams
        }
        guard let streams else { return false }
        let version = release.version
        streams.announce(version)
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
    ///
    /// A stream of ``shared`` goes on when ``configure(_:refresh:)`` is
    /// called again: it then tells of the new instance's releases.
    public var updates: AsyncStream<String> {
        state.withLock { $0.streams }.makeStream()
    }
}

/// The streams ``Localize/updates`` has handed out. They are an object of
/// their own so that `configure` can pass those of the instance it replaces
/// on to the new one.
final class UpdateStreams: Sendable {
    private let continuations = Locked<[UUID: AsyncStream<String>.Continuation]>([:])

    func makeStream() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    func announce(_ version: String) {
        let all = continuations.withLock { Array($0.values) }
        for continuation in all { continuation.yield(version) }
    }

    deinit {
        // No instance is left to tell of a release. End the streams, or a
        // consumer would wait on them forever.
        let all = continuations.withLock { Array($0.values) }
        for continuation in all { continuation.finish() }
    }
}
