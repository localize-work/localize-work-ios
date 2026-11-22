import Foundation

/// One value in a published file: a text, or an object of further values.
/// Published files hold nothing else; anything else is kept as `other` so it
/// is never mistaken for a text.
enum Node: Sendable, Equatable {
    case string(String)
    case object([String: Node])
    case other

    init(json: Any) {
        if let text = json as? String {
            self = .string(text)
        } else if let object = json as? [String: Any] {
            self = .object(object.mapValues(Node.init(json:)))
        } else {
            self = .other
        }
    }

    var json: Any {
        switch self {
        case .string(let text): return text
        case .object(let object): return object.mapValues(\.json)
        case .other: return NSNull()
        }
    }
}

/// One published file: `{version}/{locale}/{namespace}.json`.
struct FileKey: Hashable, Sendable {
    let locale: String
    let namespace: String
}

/// Every file the app needs from one release version. A release is only ever
/// built complete, so holding one means holding all of it.
struct Release: Sendable {
    let version: String
    /// A file the release does not have (404) is present here as empty.
    let files: [FileKey: [String: Node]]

    /// Whether every one of `needed` is here.
    func holds(_ needed: [FileKey]) -> Bool {
        needed.allSatisfy { files[$0] != nil }
    }

    /// This release with more files of the same version.
    func adding(_ more: [FileKey: [String: Node]]) -> Release {
        Release(version: version, files: files.merging(more) { held, _ in held })
    }

    /// Whether the release has texts in a shorter form of `locale`: for
    /// `en-FI`, a file of `en` that is not empty. A regional locale of such a
    /// language is complete without a file of its own.
    func hasTexts(inABaseOf locale: String) -> Bool {
        var parts = locale.split(separator: "-")
        while parts.count > 1 {
            parts.removeLast()
            let base = parts.joined(separator: "-")
            if files.contains(where: { $0.key.locale == base && !$0.value.isEmpty }) { return true }
        }
        return false
    }

    /// Same version and same set of files. Files of a version never change,
    /// so this is enough to tell that nothing new would be shown.
    func hasSameContents(as other: Release) -> Bool {
        version == other.version && Set(files.keys) == Set(other.files.keys)
    }
}

enum ReleaseJSON {
    /// A published file body. Nil unless it is a JSON object.
    static func file(from data: Data) -> [String: Node]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object.mapValues(Node.init(json:))
    }

    /// The version named by a `latest.json` body, if it names a valid one.
    static func pointerVersion(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? String,
              isValidVersion(version)
        else { return nil }
        return version
    }

    /// `^v[1-9]\d*$`: the letter `v` and a positive whole number without a
    /// leading zero.
    static func isValidVersion(_ version: String) -> Bool {
        let bytes = Array(version.utf8)
        guard bytes.count >= 2, bytes[0] == UInt8(ascii: "v"), bytes[1] != UInt8(ascii: "0") else { return false }
        return bytes.dropFirst().allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}
