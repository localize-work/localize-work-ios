import Foundation

/// i18next placeholders: `{{name}}`, `{{ name }}`, `{{- name}}` and
/// `{{name, format}}`. The format name is ignored.
enum Interpolation {
    /// Replaces each placeholder with what `resolve` returns for its name.
    /// A placeholder `resolve` has no value for is left as written.
    static func apply(_ text: String, resolve: (String) -> String?) -> String {
        guard text.contains("{{") else { return text }
        var output = ""
        var cursor = text.startIndex
        var close: Range<String.Index>?
        while let open = text.range(of: "{{", options: .literal, range: cursor..<text.endIndex) {
            output += text[cursor..<open.lowerBound]
            cursor = open.lowerBound
            // The closing braces found for an earlier "{{" still serve this
            // one when they lie after it, which keeps a run of braces linear.
            if let known = close, known.lowerBound >= open.upperBound {} else {
                close = text.range(of: "}}", options: .literal, range: open.upperBound..<text.endIndex)
            }
            // No closing braces ahead means no placeholder is left at all.
            guard let close else { break }
            guard let name = variableName(text[open.upperBound..<close.lowerBound]) else {
                // Not a placeholder: keep this brace and look again after it,
                // so "{{{name}}}" still finds "{{name}}" inside.
                output += "{"
                cursor = text.index(after: open.lowerBound)
                continue
            }
            output += resolve(name) ?? String(text[open.lowerBound..<close.upperBound])
            cursor = close.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// Whether the text has at least one placeholder.
    static func hasPlaceholder(_ text: String) -> Bool {
        var found = false
        _ = apply(text) { _ in
            found = true
            return nil
        }
        return found
    }

    /// The variable named between a pair of braces, or nil when the text
    /// between them is not a placeholder.
    private static func variableName(_ inner: Substring) -> String? {
        guard !inner.contains("{"), !inner.contains("}") else { return nil }
        var body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("-") {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = (body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
