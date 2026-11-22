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
            let store = storeFor(configuration)
            let instance = Localize(
                configuration: configuration,
                store: store,
                onDevice: store?.read() ?? .nothing,
                run: store.map { RunKey(folder: $0.folderIdentity, source: $0.source, version: configuration.version) }
            )
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

    /// Puts ``shared`` back to its state before `configure`, as when the
    /// app starts: what follows is a new run. For tests.
    static func resetShared() {
        commitLock.withLock { _ in
            sharedInstance.withLock { shared in
                shared?.retired.withLock { $0 = true }
                shared = nil
            }
            runs.withLock { $0 = [:] }
        }
    }

    private static let sharedInstance = Locked<Localize?>(nil)
    /// Held while a release is saved, and while an instance is retired, so
    /// an instance that was replaced never saves after its replacement began.
    /// Held while the device is read, too: a save writes the release before
    /// the file that names it, and a reader that came between the two would
    /// take the folder for a damaged one and delete it.
    private static let commitLock = Locked<Void>(())
    private static let unconfigured = Localize(
        configuration: LocalizeConfiguration(projectSlug: ""), store: nil, onDevice: .nothing, run: nil
    )

    /// What identifies the releases a configuration reads from the device:
    /// where they are kept, the CDN they came from, and the pinned version.
    private struct RunKey: Hashable {
        /// ``ReleaseStore/folderIdentity``.
        let folder: String
        let source: String
        let version: String?
    }

    /// What this run of the app reads of one project.
    private struct Run {
        /// See ``State/held``. Nil when the run has no release of the project.
        var held: Release?
    }

    /// What this run of the app reads of every project `configure` was
    /// called for. The release a run shows is decided when the app starts,
    /// and `configure` may be called many times after that: for another
    /// language, or for another project and then the first one again. Every
    /// one of those is still the same run. So the first `configure` of a
    /// project reads the device, and every later one goes on from what is
    /// kept here. A project whose saved files could not be read has no entry
    /// yet: the run has not looked (``State/unread``). It gets one when they
    /// can be read, or when the run saves a release over them. Read and
    /// written under `commitLock`.
    private static let runs = Locked<[RunKey: Run]>([:])
    private static let log = Logger(subsystem: "work.localize.sdk", category: "LocalizeWork")

    // MARK: Instance

    public let configuration: LocalizeConfiguration

    /// The locales a string is looked up in, most specific first.
    private let localeChain: [String]
    private let store: ReleaseStore?
    /// The entry of ``runs`` this instance keeps up to date; nil for an
    /// instance of the app's own, which is a run by itself.
    private let run: RunKey?
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
        /// The saved files could not be read when this instance was made, as
        /// on a device that has not been unlocked since it started. That is
        /// not a run that started with nothing: it could not look. The next
        /// refresh reads the device again, and what it finds then is the
        /// release this run started with. Once the instance has saved a
        /// release over them there is nothing left to look for, and what it
        /// saved waits for the next launch as any other download does.
        var unread = false
        var refresh: Task<LocalizeRefreshResult, Error>?
        /// The streams that hear of this instance's releases.
        var streams = UpdateStreams()
    }

    /// Creates an instance and loads the release saved on the device, if
    /// there is one. Nothing is downloaded until ``refresh()`` is called.
    public convenience init(configuration: LocalizeConfiguration) {
        let store = Self.storeFor(configuration)
        let onDevice = Self.commitLock.withLock { _ in store?.read() ?? .nothing }
        self.init(configuration: configuration, store: store, onDevice: onDevice, run: nil)
    }

    /// Where the releases of this configuration's project are kept; nil
    /// when there is no project or no folder to keep them in.
    private static func storeFor(_ configuration: LocalizeConfiguration) -> ReleaseStore? {
        if configuration.projectSlug.isEmpty { return nil }
        return (configuration.cacheDirectory ?? ReleaseStore.defaultRoot()).map {
            ReleaseStore(root: $0, projectSlug: configuration.projectSlug, cdnBaseURL: configuration.cdnBaseURL)
        }
    }

    /// - Parameters:
    ///   - onDevice: What `store` holds, read under `commitLock`.
    ///   - run: The entry of ``runs`` for an instance `configure` makes,
    ///     which is then called under `commitLock`.
    private init(
        configuration: LocalizeConfiguration,
        store: ReleaseStore?,
        onDevice: ReleaseStore.Stored,
        run: RunKey?
    ) {
        self.configuration = configuration
        localeChain = configuration.localeChain
        self.store = store
        self.run = run
        var unread = false
        let saved: Release?
        switch onDevice {
        case .release(let release): saved = Self.asked(release, by: configuration)
        case .nothing: saved = nil
        case .unreadable: (saved, unread) = (nil, true)
        }
        // The release a run shows is decided when the app starts: for the
        // first instance of a project in this run, it is the saved one.
        var started = saved
        if let run, let known = Self.runs.withLock({ $0[run] }) {
            // A later instance is still the same run, and goes on from what
            // the run reads by now. The run has looked at the device before.
            unread = false
            switch configuration.updatePolicy {
            case .nextLaunch:
                // Not from what was saved meanwhile: that waits for the next
                // launch. A run that started with nothing still has nothing,
                // and keeps showing bundled strings.
                started = known.held
            case .immediately:
                // The newest release is read as soon as it is here, and the
                // saved one is that. When a release could not be saved it is
                // in use from memory only, and is not dropped for that.
                started = saved ?? known.held
            }
        }
        // Files of a version never change, and another instance of the
        // project may have saved more of the version this run reads, such as
        // those of the language asked for now. They belong to the release.
        if let saved, let held = started, held.version == saved.version {
            started = held.adding(saved.files)
        }
        if let run, !unread {
            Self.runs.withLock { $0[run] = Run(held: started) }
        }
        // A release is used whole or not at all. After a change of language
        // the saved one lacks the new language's files: until they arrive the
        // app's bundled strings, which are in that language, are the better text.
        let needed = Self.neededFiles(localeChain, configuration.namespaces)
        let active = started.flatMap { $0.holds(needed) ? $0 : nil }
        state = Locked(State(active: active, saved: saved, held: started, unread: unread))
    }

    /// `release` when it is the one `configuration` asks for. A saved
    /// release of another version than the pinned one is not.
    private static func asked(_ release: Release, by configuration: LocalizeConfiguration) -> Release? {
        configuration.version == nil || release.version == configuration.version ? release : nil
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
    /// was in use stays in use. One thing may have changed all the same:
    /// after a change of language, the files the release this run reads
    /// lacked for the new language are fetched from that same version first,
    /// and are used and saved even when the rest of the refresh fails. Calls
    /// made while a refresh is running wait for that refresh and share its
    /// result.
    @discardableResult
    public func refresh() async throws -> LocalizeRefreshResult {
        let task = state.withLock { state -> Task<LocalizeRefreshResult, Error> in
            if let running = state.refresh { return running }
            let task = Task { [self] in
                defer { self.state.withLock { $0.refresh = nil } }
                // However the refresh of an instance that was replaced
                // meanwhile ended, well or not, its caller hears one thing:
                // that it was replaced. This is the one place that says so.
                let outcome: Result<LocalizeRefreshResult, Error>
                do {
                    outcome = .success(try await performRefresh())
                } catch {
                    outcome = .failure(error)
                }
                if retired.withLock({ $0 }) { throw LocalizeError.replaced }
                return try outcome.get()
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
        // Whether this refresh has put the release the run started with in
        // use, before anything newer was looked for: read from the device at
        // last, or made whole for the language. Lookups read other texts
        // then, also when nothing newer is published.
        var startedShowing = try await startFromDevice(needed)
        // First the release this run already reads. After a change of
        // language it lacks the new language's files; they come from that
        // same version, whatever is published now and whether or not the
        // pointer or a newer release can be reached.
        if try await completeHeldRelease(needed, loader) { startedShowing = true }

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

        // Writes nothing when the device holds this very release already.
        do {
            try save(release)
        } catch LocalizeError.replaced {
            throw LocalizeError.replaced
        } catch {
            // A release that waits for the next launch and is not saved
            // never takes effect, so that is a failure. Any release this run
            // reads is still used, from memory, and the next refresh saves
            // it: with the immediate policy the new one, and with either
            // policy more files of the version the run already reads.
            if configuration.updatePolicy == .nextLaunch, held?.version != version {
                throw LocalizeError.cacheWriteFailed(error.localizedDescription)
            }
            Self.log.error("localize.work could not save the release: \(error.localizedDescription, privacy: .public)")
        }

        switch configuration.updatePolicy {
        case .immediately:
            let changed = try await use(release)
            return changed || startedShowing ? .updated(version: version) : .upToDate(version: version)
        case .nextLaunch:
            // The published release is used in this run only when it is the
            // version the run started with: files of that version are added
            // (nothing the app has shown changes). Any other version waits
            // for the next launch, and a run that started with no release
            // keeps showing bundled strings.
            guard let held, held.version == version else {
                // When this refresh also put the release the run started with
                // in use, that is what the caller hears: the texts on screen
                // changed. The one that waits is told of by the next refresh.
                if startedShowing, let reading = state.withLock({ $0.active?.version }) {
                    return .updated(version: reading)
                }
                return .pendingNextLaunch(version: version)
            }
            let changed = try await use(held.adding(release.files))
            return changed || startedShowing ? .updated(version: version) : .upToDate(version: version)
        }
    }

    /// Saves `release` as the one on the device, unless it is that already.
    ///
    /// - Parameter replacingAnotherVersion: False for files added to the
    ///   release this run reads. They are saved only while the device still
    ///   names that version: another instance of the project may have saved
    ///   a newer release since, and that one is for the next launch to read.
    private func save(_ release: Release, replacingAnotherVersion: Bool = true) throws {
        // An instance that `configure` has replaced must not write its
        // release over the one its replacement saves.
        let onDevice = try Self.commitLock.withLock { _ -> Release in
            if retired.withLock({ $0 }) { throw LocalizeError.replaced }
            guard let store else { throw CocoaError(.fileNoSuchFile) }
            // What this instance saved last does not tell what the device
            // holds: another instance of the project may have saved another
            // version since, or this version with other files. So the device
            // is asked.
            var whole = release
            if let there = store.load() {
                if there.version == release.version {
                    // Files of a version never change, so those another
                    // instance saved, for another language say, are kept.
                    whole = release.adding(there.files)
                    // Nothing to write when the device has every file.
                    if whole.hasSameContents(as: there) { return there }
                } else if !replacingAnotherVersion {
                    return there
                }
            }
            try store.save(whole)
            // What was on the device before is gone now. A run that could
            // not read it has nothing left to look for there, and what it
            // holds by now is what it started with.
            let (wasLooking, held) = state.withLock { state -> (Bool, Release?) in
                defer { state.unread = false }
                return (state.unread, state.held)
            }
            if wasLooking, let run { Self.runs.withLock { $0[run] = Run(held: held) } }
            return whole
        }
        state.withLock { $0.saved = onDevice }
    }

    /// Reads the device again when it could not be read as this instance was
    /// made (``State/unread``). What is there now is the release this run
    /// started with, and is put in use when it is whole for the language.
    /// True when that changed what lookups read.
    private func startFromDevice(_ needed: [FileKey]) async throws -> Bool {
        guard state.withLock({ $0.unread }) else { return false }
        let whole = try Self.commitLock.withLock { _ -> Release? in
            if retired.withLock({ $0 }) { throw LocalizeError.replaced }
            let found: Release?
            switch store?.read() ?? .nothing {
            case .unreadable: return nil
            case .nothing: found = nil
            case .release(let release): found = Self.asked(release, by: configuration)
            }
            let held = state.withLock { state -> Release? in
                state.unread = false
                // Not in place of a release the run has put in use from
                // memory meanwhile. (One it saved itself is not found here:
                // a save ends the looking, see `save`.)
                if state.held == nil { state.held = found }
                state.saved = found
                return state.held
            }
            if let run { Self.runs.withLock { $0[run] = Run(held: held) } }
            return state.withLock { $0.active == nil ? held.flatMap { $0.holds(needed) ? $0 : nil } : nil }
        }
        guard let whole else { return false }
        return try await use(whole)
    }

    /// Makes the release this run reads whole for the current language, from
    /// its own version, and puts it in use. True when that changed what
    /// lookups read. Nothing is thrown: when the files cannot be had now, the
    /// app shows bundled strings and the next refresh tries again. The one
    /// error is ``LocalizeError/replaced``, of an instance that has been
    /// replaced and so puts nothing in use any more.
    private func completeHeldRelease(_ needed: [FileKey], _ loader: ReleaseLoader) async throws -> Bool {
        let (active, held, saved) = state.withLock { ($0.active, $0.held, $0.saved) }
        guard active == nil, let held, let whole = await completed(held, needed, loader) else { return false }
        // The copy on the device gets the files too while it is this
        // version, so the next launch starts whole. A failure only costs
        // that; the files are in use from memory.
        if let saved, saved.version == whole.version {
            try? save(whole, replacingAnotherVersion: false)
        }
        return try await use(whole)
    }

    /// `release` with the files of `needed` it lacks, fetched from its own
    /// version; nil when it cannot be made whole.
    ///
    /// Nothing has named this release as the published one. If it answers
    /// "not found" for the language asked for, it may be gone from the CDN,
    /// or have nothing in that language, and reading it with empty files
    /// would show its fallback language in place of the app's bundled
    /// strings. So when a file of the locale asked for or of its shorter
    /// forms is missing, the release must have shown that it has the
    /// language: one of those files was found now, or it already has texts
    /// in one of them, in the namespaces the app asks for. A file of the
    /// fallback locale shows nothing of the kind. With that shown, a file it
    /// does not have is an empty one, as for a regional locale without
    /// overrides of its own or a namespace the language has no texts in.
    private func completed(_ release: Release, _ needed: [FileKey], _ loader: ReleaseLoader) async -> Release? {
        let missing = needed.filter { release.files[$0] == nil }
        // The locale asked for and its shorter forms, without the fallback locale.
        let asked = LocaleCode.chain(locale: configuration.locale, fallback: nil)
        var files: [FileKey: [String: Node]] = [:]
        var found = false
        for file in missing {
            do {
                if let contents = try await loader.file(version: release.version, file: file) {
                    if asked.contains(file.locale) { found = true }
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
        let lacksAsked = missing.contains { asked.contains($0.locale) }
        if lacksAsked, !found, !release.hasTexts(in: asked, namespaces: configuration.namespaces) { return nil }
        return release.adding(files)
    }

    /// Makes `release` the one lookups read and announces it. False when it
    /// is what they read already. An instance that has been replaced puts
    /// nothing in use and announces nothing: it throws ``LocalizeError/replaced``.
    private func use(_ release: Release) async throws -> Bool {
        let version = release.version
        // Under the lock an instance is retired under, so this happens
        // wholly before the instance is replaced or not at all. The streams
        // are told here too: afterwards they belong to the new instance.
        let changed = try Self.commitLock.withLock { _ -> Bool in
            if retired.withLock({ $0 }) { throw LocalizeError.replaced }
            let changed = state.withLock { state -> Bool in
                if let active = state.active, active.hasSameContents(as: release) { return false }
                state.active = release
                state.held = release
                state.streams.announce(version)
                return true
            }
            // Whichever instance `configure` makes next for this project
            // goes on from here.
            if changed, let run { Self.runs.withLock { $0[run] = Run(held: release) } }
            return changed
        }
        guard changed else { return false }
        await MainActor.run {
            if retired.withLock({ $0 }) { return }
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
