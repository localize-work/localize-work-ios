import Foundation

/// The release kept on the device, so strings are there at launch and
/// offline.
///
/// One folder per project holds `current.json`, naming a version, and that
/// version's `v12.json` with every file of the release in it. A release is
/// written whole before `current.json` names it, so what `current.json`
/// names is always complete.
struct ReleaseStore: Sendable {
    /// The folder of this project.
    let directory: URL
    let projectSlug: String
    /// The CDN the release came from, as ``ReleaseLoader/base(_:)`` writes
    /// it. A release cached from another CDN has version numbers of its own
    /// and is not this project's release.
    let source: String

    init(root: URL, projectSlug: String, cdnBaseURL: URL) {
        directory = root.appendingPathComponent(Self.folderName(projectSlug), isDirectory: true)
        self.projectSlug = projectSlug
        source = ReleaseLoader.base(cdnBaseURL)
    }

    /// One name for the folder, however the configuration wrote its path:
    /// with `/.` in it, through a symbolic link, with or without a slash at
    /// the end. Two configurations with the same one share the saved files.
    ///
    /// The name is the same before the folder exists and after: a first
    /// launch creates it, and is still the same run afterwards. So the part
    /// of the path that exists is resolved, and the rest is added to it as
    /// written. (Foundation's own resolving leaves a path alone until all of
    /// it exists, and then gives another one.)
    var folderIdentity: String {
        var existing = directory.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(URL(fileURLWithPath: String(cString: resolved))) {
                    $0.appendingPathComponent($1)
                }.path
            }
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path || existing.path == "/" { return directory.standardizedFileURL.path }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
    }

    /// What the device holds for this project.
    enum Stored {
        case release(Release)
        case nothing
        /// The files cannot be looked at now: they are locked, as on a
        /// device that has not been unlocked since it started, or a folder
        /// on the way to them cannot be entered. That says nothing about
        /// what they hold, so they stay, and are worth reading again later.
        case unreadable
    }

    /// What is saved. A saved release that is damaged or incomplete is
    /// deleted and counts as nothing.
    func read() -> Stored {
        // Not `fileExists` first: it answers "no" for a folder it cannot
        // look into, which is not a folder that is not there. Reading the
        // file tells the two apart.
        switch readFiles() {
        case .release(let release):
            return .release(release)
        case .damaged:
            discard()
            return .nothing
        case .unreadable:
            return .unreadable
        }
    }

    /// The saved release, or nil when there is none or it cannot be read.
    func load() -> Release? {
        if case .release(let release) = read() { return release }
        return nil
    }

    /// Saves `release` as the current one and deletes every other version.
    func save(_ release: Release) throws {
        guard ReleaseJSON.isValidVersion(release.version) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let files = release.files
            .sorted { ($0.key.locale, $0.key.namespace) < ($1.key.locale, $1.key.namespace) }
            .map { key, contents -> [String: Any] in
                ["locale": key.locale, "namespace": key.namespace, "contents": contents.mapValues(\.json)]
            }
        let body: [String: Any] = [
            "format": Self.format,
            "projectSlug": projectSlug,
            "source": source,
            "version": release.version,
            "files": files,
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Published translations can be downloaded again; they do not belong
        // in the user's device backup.
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try JSONSerialization.data(withJSONObject: body).write(to: releaseURL(release.version), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["version": release.version])
            .write(to: currentURL, options: .atomic)
        removeEverything(except: [currentURL.lastPathComponent, releaseURL(release.version).lastPathComponent])
    }

    /// Deletes everything saved for this project.
    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    private enum Saved {
        case release(Release)
        /// Not a complete, valid release of this project. No folder at all
        /// is one case of it.
        case damaged
        /// The files could not be looked at. They may be fine.
        case unreadable
    }

    private func readFiles() -> Saved {
        guard let pointer = data(at: currentURL) else { return .unreadable }
        guard let pointer, let version = ReleaseJSON.pointerVersion(from: pointer) else { return .damaged }
        guard let data = data(at: releaseURL(version)) else { return .unreadable }
        guard let data,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              body["format"] as? Int == Self.format,
              body["projectSlug"] as? String == projectSlug,
              // The same CDN written another way, with a slash at the end
              // say, is the same source.
              (body["source"] as? String).map(ReleaseLoader.base) == source,
              body["version"] as? String == version,
              let entries = body["files"] as? [[String: Any]]
        else { return .damaged }
        var files: [FileKey: [String: Node]] = [:]
        for entry in entries {
            guard let locale = entry["locale"] as? String,
                  let namespace = entry["namespace"] as? String,
                  let contents = entry["contents"] as? [String: Any]
            else { return .damaged }
            files[FileKey(locale: locale, namespace: namespace)] = contents.mapValues(Node.init(json:))
        }
        return .release(Release(version: version, files: files))
    }

    /// A file's bytes; `.some(nil)` when no file is there, and nil when
    /// that cannot be told: the file is locked, or a folder on the way to it
    /// cannot be entered.
    private func data(at url: URL) -> Data?? {
        do {
            return .some(try Data(contentsOf: url))
        } catch {
            // The system's own reason says more than Foundation's code,
            // which is "unknown" for half of these. No such file, a folder on
            // the way that is a file, a folder where the file should be: in
            // each of them the path was looked at and holds no file.
            let reason = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            if let reason, reason.domain == NSPOSIXErrorDomain, [ENOENT, ENOTDIR, EISDIR].contains(Int32(reason.code)) {
                return .some(nil)
            }
            if let error = error as? CocoaError, error.code == .fileReadNoSuchFile { return .some(nil) }
            return nil
        }
    }

    private func removeEverything(except kept: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private var currentURL: URL {
        directory.appendingPathComponent("current.json")
    }

    /// Only called with a version that passed `isValidVersion`, so the name
    /// is the letter `v` and digits.
    private func releaseURL(_ version: String) -> URL {
        directory.appendingPathComponent("\(version).json")
    }

    /// A folder name that is the slug for an ordinary slug, and cannot leave
    /// the cache folder for any other.
    static func folderName(_ projectSlug: String) -> String {
        projectSlug.addingPercentEncoding(withAllowedCharacters: folderNameCharacters) ?? "project"
    }

    private static let folderNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    /// The layout of the saved file. Raise it when the layout changes; older
    /// files are then discarded and downloaded again.
    private static let format = 1

    /// Where releases are kept unless the configuration names a folder.
    /// Application Support, so the system does not clear it when space runs
    /// low; tvOS offers only Caches.
    static func defaultRoot() -> URL? {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #endif
        // On macOS the folder is shared by every app of the user, so the
        // app's identifier keeps two apps with one project apart.
        let app = Bundle.main.bundleIdentifier ?? "app"
        return base?
            .appendingPathComponent("LocalizeWork", isDirectory: true)
            .appendingPathComponent(folderName(app), isDirectory: true)
    }
}
