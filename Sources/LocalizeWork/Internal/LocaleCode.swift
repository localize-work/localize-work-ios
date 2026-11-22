import Foundation

/// BCP 47 locale codes as localize.work writes them: `en`, `en-FI`, `zh-Hans`.
enum LocaleCode {
    /// Language codes that older systems still report, and their current
    /// spelling, which is the one a project's locales use.
    private static let legacyLanguages = ["iw": "he", "in": "id", "ji": "yi"]

    /// `en_fi` and `EN-fi` become `en-FI`, the form used in published paths.
    /// Extensions (`-u-…`, `-x-…`), which a device adds for things like the
    /// calendar, are dropped: a published locale never has them. Beyond that
    /// the code is taken as written, so a locale must be spelled the way the
    /// project spells it.
    static func canonical(_ raw: String) -> String {
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
        var out: [String] = []
        for (index, part) in parts.enumerated() {
            let text = String(part)
            if index == 0 {
                let language = text.lowercased()
                out.append(legacyLanguages[language] ?? language)
                continue
            }
            if text.count == 1 { break }
            let isLetters = text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            if isLetters && text.count == 4 {
                out.append(text.prefix(1).uppercased() + text.dropFirst().lowercased())
            } else if isLetters && text.count == 2 {
                out.append(text.uppercased())
            } else {
                out.append(text.lowercased())
            }
        }
        return out.joined(separator: "-")
    }

    /// The locales a string is looked up in, most specific first: the locale
    /// and each shorter form of it, then the fallback locale and its shorter
    /// forms, each once. `en-FI` with fallback `et` gives `en-FI`, `en`, `et`.
    static func chain(locale: String, fallback: String?) -> [String] {
        var chain: [String] = []
        func addWithParents(_ code: String) {
            var parts = code.split(separator: "-")
            while !parts.isEmpty {
                let joined = parts.joined(separator: "-")
                if !chain.contains(joined) { chain.append(joined) }
                parts.removeLast()
            }
        }
        addWithParents(canonical(locale))
        if let fallback { addWithParents(canonical(fallback)) }
        return chain
    }
}
