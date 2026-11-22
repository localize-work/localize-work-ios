import Foundation

/// Finds a key in one published file the way i18next does.
enum KeyLookup {
    /// The text at `key`, or nil when the file has no text there. An empty
    /// text is a text.
    ///
    /// The key is first walked through the nested objects segment by segment.
    /// When that does not end at a text, the remaining segments are joined
    /// into one name at each level. That is how a key that the publisher wrote
    /// under its full dotted name is found: `a.b` beside a text `a` is stored
    /// as `{ "a": "…", "a.b": "…" }`.
    static func string(in file: [String: Node], key: String) -> String? {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        switch walk(file, segments) {
        case .string(let text)? where !text.isEmpty:
            return text
        case .object?:
            // A group of keys, not a text. i18next stops here too.
            return nil
        default:
            break
        }
        if case .string(let text)? = deepFind(file, key, segments) { return text }
        return nil
    }

    /// The names to try for `key` with a count, most specific first:
    /// `key_zero` for 0, the count's plural category in the language of
    /// `locale`, `key_other`, then the plain key.
    static func candidates(key: String, count: Int?, locale: String) -> [String] {
        guard let count else { return [key] }
        let category = PluralRules.category(for: count, locale: locale)
        var names: [String] = []
        if count == 0 && category != .zero { names.append("\(key)_\(PluralCategory.zero.rawValue)") }
        names.append("\(key)_\(category.rawValue)")
        if category != .other { names.append("\(key)_\(PluralCategory.other.rawValue)") }
        names.append(key)
        return names
    }

    private static func walk(_ file: [String: Node], _ segments: [String]) -> Node? {
        var current = Node.object(file)
        for segment in segments {
            guard case .object(let object) = current, let next = object[segment] else { return nil }
            current = next
        }
        return current
    }

    /// i18next's `deepFind`: at each level take the shortest run of segments,
    /// joined with dots, that names something. A text is only taken when no
    /// segments are left after it.
    private static func deepFind(_ file: [String: Node], _ key: String, _ segments: [String]) -> Node? {
        if let whole = file[key], whole != .string("") { return whole }
        var current: Node? = .object(file)
        var index = 0
        while index < segments.count {
            guard case .object(let object)? = current else { return nil }
            var found: Node?
            var name = ""
            for end in index..<segments.count {
                name += end == index ? segments[end] : ".\(segments[end])"
                found = object[name]
                guard let value = found else { continue }
                if case .object = value {} else if end < segments.count - 1 { continue }
                index = end + 1
                break
            }
            current = found
        }
        return current
    }
}
