import Foundation

/// BCP 47 locale codes as localize.work writes them: `en`, `en-FI`, `zh-Hans`.
enum LocaleCode {
    /// `en_fi` and `EN-fi` become `en-FI`, the form used in published paths.
    static func canonical(_ raw: String) -> String {
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
        return parts.enumerated().map { index, part -> String in
            let text = String(part)
            if index == 0 { return text.lowercased() }
            let isLetters = text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            if isLetters && text.count == 4 { return text.prefix(1).uppercased() + text.dropFirst().lowercased() }
            if isLetters && text.count == 2 { return text.uppercased() }
            return text
        }.joined(separator: "-")
    }

    /// The locales a string is looked up in, most specific first: the locale,
    /// each shorter form of it, then the fallback locale. `en-FI` with
    /// fallback `et` gives `en-FI`, `en`, `et`.
    static func chain(locale: String, fallback: String?) -> [String] {
        var chain: [String] = []
        func add(_ code: String) {
            if !code.isEmpty && !chain.contains(code) { chain.append(code) }
        }
        var parts = canonical(locale).split(separator: "-")
        while !parts.isEmpty {
            add(parts.joined(separator: "-"))
            parts.removeLast()
        }
        if let fallback { add(canonical(fallback)) }
        return chain
    }
}
