import Foundation

/// The strings shipped inside the app, used when the release has no text for
/// a key.
enum BundledStrings {
    /// The tables of a bundle that are written in one language.
    struct Localization: @unchecked Sendable {
        /// The localization's folder, opened as a bundle of its own: a lookup
        /// in it reads these tables and no other language's.
        let tables: Bundle
        /// Its name in the app bundle, such as `pt-BR`.
        let name: String
    }

    /// The localizations of `bundle` in the language of `locale`, in the
    /// order to read them; none when the bundle does not have the language.
    /// The choice is the system's, as for a device set to `locale`: `en-FI`
    /// reads `en-GB`, then `en`. A localization in another language, which
    /// the system would fall back to, is not among them.
    static func localizations(of bundle: Bundle, for locale: String) -> [Localization] {
        let names = bundle.localizations.filter { $0 != "Base" }
        let wanted = subtags(of: locale)
        return Bundle.preferredLocalizations(from: names, forPreferences: [locale]).compactMap { name in
            let found = subtags(of: name)
            guard found.language == wanted.language else { return nil }
            // Two ways of writing a language are two languages to a reader.
            if let written = found.script, let asked = wanted.script, written != asked { return nil }
            guard let folder = bundle.url(forResource: name, withExtension: "lproj"),
                  let tables = Bundle(url: folder)
            else { return nil }
            return Localization(tables: tables, name: name)
        }
    }

    /// The string for `key` that iOS picks for the app, with the values
    /// filled in, or nil when the bundle has none. The table named after the
    /// namespace is tried first, then the default table (`Localizable`).
    static func string(
        key: String,
        namespace: String,
        bundle: Bundle,
        arguments: LocalizeArguments,
        count: Int?,
        device: Locale = .current
    ) -> String? {
        string(
            key: key, namespace: namespace, tables: bundle, written: picked(of: bundle),
            arguments: arguments, count: count, device: device
        )
    }

    /// The string for `key` in one localization, or nil when its tables have
    /// none.
    static func string(
        key: String,
        namespace: String,
        in localization: Localization,
        arguments: LocalizeArguments,
        count: Int?,
        device: Locale = .current
    ) -> String? {
        string(
            key: key, namespace: namespace, tables: localization.tables, written: localization.name,
            arguments: arguments, count: count, device: device
        )
    }

    /// - Parameter written: The localization the strings of `tables` are
    ///   written in.
    private static func string(
        key: String,
        namespace: String,
        tables: Bundle,
        written: String,
        arguments: LocalizeArguments,
        count: Int?,
        device: Locale
    ) -> String? {
        guard !key.isEmpty else { return nil }
        for table in [namespace, nil] {
            let found = tables.localizedString(forKey: key, value: missing, table: table)
            if found != missing {
                return fill(found, arguments: arguments, count: count, locale: formatLocale(written: written, device: device))
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

    /// The localization iOS reads the strings of `bundle` from.
    private static func picked(of bundle: Bundle) -> String {
        let localization = bundle.preferredLocalizations.first ?? "en"
        return localization == "Base" ? bundle.developmentLocalization ?? "en" : localization
    }

    /// The locale to format a string of `bundle` with, as iOS picks it.
    static func formatLocale(of bundle: Bundle, device: Locale = .current) -> Locale {
        formatLocale(written: picked(of: bundle), device: device)
    }

    /// The locale to format a string with that is written in the
    /// localization `written`. Foundation picks the plural form by this
    /// locale, so it has to be the language the string is written in, which
    /// is not the device's when the string comes from another language's
    /// table.
    static func formatLocale(written localization: String, device: Locale = .current) -> Locale {
        let written = Locale(identifier: localization)
        guard language(of: written) == language(of: device) else { return written }
        // The same language can count differently by region: zero is
        // singular in Brazilian Portuguese and plural in European. A string
        // written for one keeps its own rule on a device set to the other.
        guard PluralRules.family(for: tag(of: written)) == PluralRules.family(for: tag(of: device)) else {
            return written
        }
        // Otherwise the device's locale, and with it the region's way of
        // writing numbers.
        return device
    }

    /// The identifier without what follows an `@`: `pt_PT` of `pt_PT@calendar=…`.
    private static func tag(of locale: Locale) -> String {
        String(locale.identifier.split(separator: "@").first ?? "")
    }

    private static func language(of locale: Locale) -> String {
        let code = locale.identifier.split(whereSeparator: { "_-@".contains($0) }).first ?? ""
        return code.lowercased()
    }

    /// The language of a locale code and, when the code names one, the
    /// script: `zh` and `Hant` of `zh-Hant-TW`.
    private static func subtags(of code: String) -> (language: String, script: String?) {
        let parts = LocaleCode.canonical(code).split(separator: "-")
        // Norwegian is written `no` by some and `nb` by others.
        let language = parts.first.map { $0 == "no" ? "nb" : String($0) } ?? ""
        let second = parts.dropFirst().first.map(String.init)
        let script = second.flatMap { $0.count == 4 && $0.allSatisfy(\.isLetter) ? $0 : nil }
        return (language, script)
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
