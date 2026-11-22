import Foundation

/// The strings shipped inside the app, used when the release has no text for
/// a key.
enum BundledStrings {
    /// The bundled string for `key`, with the values filled in, or nil when
    /// the bundle has none. The table named after the namespace is tried
    /// first, then the default table (`Localizable`).
    static func string(
        key: String,
        namespace: String,
        bundle: Bundle,
        arguments: LocalizeArguments,
        count: Int?
    ) -> String? {
        guard !key.isEmpty else { return nil }
        for table in [namespace, nil] {
            let found = bundle.localizedString(forKey: key, value: missing, table: table)
            if found != missing {
                return fill(found, arguments: arguments, count: count, locale: formatLocale(of: bundle))
            }
        }
        return nil
    }

    /// Fills the values into a bundled string.
    ///
    /// A bundled string is written one of two ways. With `{{name}}`
    /// placeholders it is filled like a published string. Otherwise it is a
    /// format string as Xcode and localize.work's string catalog export write
    /// it (`%@`, `%1$@`, `%lld`, plural variations), and Foundation fills it:
    /// that is what picks the plural form of a catalog entry.
    static func fill(
        _ format: String,
        arguments: LocalizeArguments,
        count: Int?,
        locale: Locale = .current
    ) -> String {
        if Interpolation.hasPlaceholder(format) {
            return Interpolation.apply(format) { name in
                if name == "count", let count { return String(count) }
                return arguments.value(named: name).map(LocalizeArguments.text)
            }
        }
        // An app passes values only to a string that takes some, and only
        // such a string doubles its literal percent signs. Without values the
        // text is shown as it is.
        guard count != nil || !arguments.pairs.isEmpty else { return format }
        guard let kinds = PrintfFormat.arguments(of: format) else { return format }

        // The count goes where the format reads a number: the plural rule, or
        // failing that the first integer. The named values fill the other
        // positions in the order they were written.
        var countPosition: Int?
        if count != nil {
            let positions = kinds.keys.sorted()
            countPosition = positions.first { kinds[$0] == .pluralRule }
                ?? positions.first { [.int32, .int, .int64].contains(kinds[$0]) }
                ?? 1
        }
        let total = max(kinds.keys.max() ?? 0, arguments.pairs.count + (count == nil ? 0 : 1))
        var named = arguments.pairs.makeIterator()
        var values: [CVarArg] = []
        for position in 1...max(total, 1) {
            let value: Any? = position == countPosition ? count : named.next()?.value
            switch kinds[position] {
            case .int32: values.append(Int32(truncatingIfNeeded: integer(value)))
            case .int: values.append(Int(truncatingIfNeeded: integer(value)))
            case .int64, .pluralRule: values.append(integer(value))
            case .double: values.append(double(value))
            // A position the format string does not show is read, if at all,
            // inside a plural variation, where it is a `%@`.
            case .object, nil: values.append((value.map(LocalizeArguments.text) ?? "") as NSString)
            }
        }
        // `format` is passed as Foundation returned it: for a plural entry it
        // carries the variations, which a copy of its characters would lose.
        return String(format: format, locale: locale, arguments: values)
    }

    /// The locale to format a string of `bundle` with. Foundation picks the
    /// plural form by this locale's language, so it has to be the language
    /// the string is written in, which is not the device's when the app has
    /// no localization for the device's language.
    static func formatLocale(of bundle: Bundle) -> Locale {
        var localization = bundle.preferredLocalizations.first ?? "en"
        if localization == "Base" { localization = bundle.developmentLocalization ?? "en" }
        let written = Locale(identifier: localization)
        // Same language: keep the device's locale, and with it the region's
        // way of writing numbers.
        return language(of: written) == language(of: .current) ? .current : written
    }

    private static func language(of locale: Locale) -> String {
        let code = locale.identifier.split(whereSeparator: { "_-@".contains($0) }).first ?? ""
        return code.lowercased()
    }

    private static func integer(_ value: Any?) -> Int64 {
        switch value {
        case let number as any BinaryInteger: return Int64(truncatingIfNeeded: number)
        case let number as any BinaryFloatingPoint: return Int64(exactly: Double(number).rounded()) ?? 0
        case let text as String: return Int64(text) ?? 0
        default: return 0
        }
    }

    private static func double(_ value: Any?) -> Double {
        switch value {
        case let number as any BinaryFloatingPoint: return Double(number)
        case let number as any BinaryInteger: return Double(number)
        case let text as String: return Double(text) ?? 0
        default: return 0
        }
    }

    /// Returned by the bundle when it has no string for a key.
    private static let missing = "\u{1}localize.work.missing\u{1}"
}
