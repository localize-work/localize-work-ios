import XCTest
@testable import LocalizeWork

/// The app's own string tables as the last source of a text. The tables are
/// written the way a compiled string catalog is laid out, including the
/// plural entries of localize.work's `.xcstrings` export.
final class BundledStringsTests: LocalizeTestCase {
    private var bundleDirectories: [URL] = []

    override func tearDown() {
        for directory in bundleDirectories { try? FileManager.default.removeItem(at: directory) }
        bundleDirectories = []
        super.tearDown()
    }

    /// A bundle with one localization holding the given tables.
    private func makeBundle(
        strings: [String: [String: String]],
        plurals: [String: [String: Any]] = [:],
        localization: String = "en"
    ) throws -> Bundle {
        try makeBundle(localizations: [localization: (strings, plurals)])
    }

    /// A bundle with several localizations, each holding its own tables.
    private func makeBundle(
        localizations: [String: (strings: [String: [String: String]], plurals: [String: [String: Any]])],
        developmentRegion: String? = nil
    ) throws -> Bundle {
        let bundleDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalizeWorkBundle-\(UUID().uuidString).bundle", isDirectory: true)
        bundleDirectories.append(bundleDirectory)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        if let developmentRegion {
            try PropertyListSerialization
                .data(fromPropertyList: ["CFBundleDevelopmentRegion": developmentRegion], format: .xml, options: 0)
                .write(to: bundleDirectory.appendingPathComponent("Info.plist"))
        }
        for (localization, tables) in localizations {
            let lproj = bundleDirectory.appendingPathComponent("\(localization).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            for (table, entries) in tables.strings {
                try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
                    .write(to: lproj.appendingPathComponent("\(table).strings"))
            }
            for (table, entries) in tables.plurals {
                try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
                    .write(to: lproj.appendingPathComponent("\(table).stringsdict"))
            }
        }
        return try XCTUnwrap(Bundle(url: bundleDirectory))
    }

    /// A bundle whose localizations each hold the same one table of strings.
    private func makeBundle(tables: [String: [String: String]]) throws -> Bundle {
        try makeBundle(localizations: tables.mapValues { (["Localizable": $0], [:]) })
    }

    /// A plural entry as Xcode compiles a catalog's plural variations.
    private func plural(_ formatKey: String, _ variable: String, _ forms: [String: String]) -> [String: Any] {
        var rule: [String: Any] = [
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "lld",
        ]
        rule.merge(forms) { $1 }
        return ["NSStringLocalizedFormatKey": formatKey, variable: rule]
    }

    private func localize(_ bundle: Bundle, release: [String: Any]? = nil) async throws -> Localize {
        if let release {
            return try await loaded(["en/translation": release], bundle: bundle)
        }
        return Localize(configuration: configuration(bundle: bundle))
    }

    func testABundledStringIsUsedWhenTheReleaseLacksTheKey() async throws {
        let bundle = try makeBundle(strings: ["Localizable": ["nav.home": "Home (bundled)", "both": "bundled"]])
        let localize = try await localize(bundle, release: ["both": "published"])

        XCTAssertEqual(localize.string("nav.home"), "Home (bundled)")
        // The release wins where it has the key.
        XCTAssertEqual(localize.string("both"), "published")
        // The bundle wins over the caller's fallback, which wins over the key.
        XCTAssertEqual(localize.string("nav.home", fallback: "Fallback"), "Home (bundled)")
        XCTAssertEqual(localize.string("nowhere", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(localize.string("nowhere"), "nowhere")
    }

    func testBundledStringsServeAFirstLaunchWithoutAnyRelease() async throws {
        let bundle = try makeBundle(strings: ["Localizable": ["nav.home": "Home (bundled)"]])
        let localize = try await localize(bundle)
        XCTAssertNil(localize.version)
        XCTAssertEqual(localize.string("nav.home"), "Home (bundled)")
    }

    func testTheNamespaceTableIsTriedBeforeTheDefaultTable() async throws {
        let bundle = try makeBundle(strings: [
            "Localizable": ["pay": "Pay (default table)", "only.default": "Default"],
            "checkout": ["pay": "Pay (checkout table)"],
        ])
        let localize = try await localize(bundle)

        XCTAssertEqual(localize.string("pay", namespace: "checkout"), "Pay (checkout table)")
        XCTAssertEqual(localize.string("pay"), "Pay (default table)")
        XCTAssertEqual(localize.string("only.default", namespace: "checkout"), "Default")
    }

    func testFormatArgumentsAreFilledInTheOrderWritten() async throws {
        let bundle = try makeBundle(strings: ["Localizable": [
            "greeting": "Hello, %@!",
            "route": "From %1$@ to %2$@",
            "reversed": "To %2$@ from %1$@",
            "twice": "%1$@, meet %1$@",
            "discount": "%@ gets 20%% off",
            "points": "%@ points",
            "level": "Level %d of %ld, %.1f%% done",
        ]])
        let localize = try await localize(bundle)

        XCTAssertEqual(localize.string("greeting", ["name": "Ann"]), "Hello, Ann!")
        XCTAssertEqual(localize.string("route", ["from": "Tartu", "to": "Tallinn"]), "From Tartu to Tallinn")
        XCTAssertEqual(localize.string("reversed", ["from": "Tartu", "to": "Tallinn"]), "To Tallinn from Tartu")
        XCTAssertEqual(localize.string("twice", ["name": "Ann"]), "Ann, meet Ann")
        XCTAssertEqual(localize.string("discount", ["name": "Ann"]), "Ann gets 20% off")
        XCTAssertEqual(localize.string("greeting", ["number": 7]), "Hello, 7!")
        // A count shown by a string that is not a plural is a `%@` there.
        XCTAssertEqual(localize.string("points", count: 3), "3 points")
        XCTAssertEqual(localize.string("points", ["count": 3]), "3 points")
        // Numbers are written the way the device's region writes them.
        let decimal = Locale.current.decimalSeparator ?? "."
        XCTAssertEqual(
            localize.string("level", ["level": 2, "of": 9, "done": 12.5]),
            "Level 2 of 9, 12\(decimal)5% done"
        )
        // Values of another kind than the format reads are converted, never
        // passed as they are.
        XCTAssertEqual(
            localize.string("level", ["level": "2", "of": "x", "done": 3]),
            "Level 2 of 0, 3\(decimal)0% done"
        )
    }

    func testAStringCalledWithoutValuesIsShownAsItIs() async throws {
        let bundle = try makeBundle(strings: ["Localizable": [
            "progress": "100% done",
            "greeting": "Hello, %@!",
        ]])
        let localize = try await localize(bundle)

        XCTAssertEqual(localize.string("progress"), "100% done")
        XCTAssertEqual(localize.string("greeting"), "Hello, %@!")
    }

    func testMissingValuesAreFilledWithNothing() async throws {
        let bundle = try makeBundle(strings: ["Localizable": ["route": "From %1$@ to %2$@ in %3$lld h"]])
        let localize = try await localize(bundle)
        XCTAssertEqual(localize.string("route", ["from": "Tartu"]), "From Tartu to  in 0 h")
    }

    func testAFormatTheSDKCannotFillSafelyIsShownAsItIs() async throws {
        let bundle = try makeBundle(strings: ["Localizable": [
            "cstring": "Hello, %s!",
            "star": "Width %*d",
            "char": "Letter %c",
            "pointer": "At %p",
            "written": "%n",
            "mixed": "%1$@ and %@",
            "twoKinds": "%1$@ and %1$lld",
            "trailing": "100%",
        ]])
        let localize = try await localize(bundle)
        XCTAssertEqual(localize.string("cstring", ["name": "Ann"]), "Hello, %s!")
        XCTAssertEqual(localize.string("star", ["width": 3, "value": 4]), "Width %*d")
        XCTAssertEqual(localize.string("char", ["letter": "a"]), "Letter %c")
        XCTAssertEqual(localize.string("pointer", ["x": 1]), "At %p")
        XCTAssertEqual(localize.string("written", ["x": 1]), "%n")
        XCTAssertEqual(localize.string("mixed", ["a": "A", "b": "B"]), "%1$@ and %@")
        XCTAssertEqual(localize.string("twoKinds", ["a": "A"]), "%1$@ and %1$lld")
        XCTAssertEqual(localize.string("trailing", ["a": "A"]), "100%")
    }

    func testABundledStringMayUsePublishedStylePlaceholders() async throws {
        let bundle = try makeBundle(strings: ["Localizable": [
            "greeting": "Hello, {{name}}! 100% yours, {{count}} times",
        ]])
        let localize = try await localize(bundle)
        XCTAssertEqual(localize.string("greeting", ["name": "Ann"], count: 2), "Hello, Ann! 100% yours, 2 times")
        XCTAssertEqual(localize.string("greeting"), "Hello, {{name}}! 100% yours, {{count}} times")
    }

    func testBundledPluralsFromAStringCatalog() async throws {
        let bundle = try makeBundle(
            strings: ["Localizable": ["plain": "Plain"]],
            plurals: ["Localizable": [
                // "%lld item" / "%lld items"
                "items": plural("%#@value@", "value", ["one": "%lld item", "other": "%lld items"]),
                // "%1$@ has %2$lld message(s)": the count is the second argument.
                "inbox": plural("%2$#@value@", "value", [
                    "one": "%1$@ has %2$lld message",
                    "other": "%1$@ has %2$lld messages",
                ]),
                // The export's form for a plural that never shows the number.
                "survivors": plural("%2$#@count@", "count", [
                    "one": "%1$@ has one survivor",
                    "other": "%1$@ has several survivors",
                ]),
                "sent": plural("%3$#@value@", "value", [
                    "one": "%1$@ sent %2$@ %3$lld file",
                    "other": "%1$@ sent %2$@ %3$lld files",
                ]),
            ]]
        )
        let localize = try await localize(bundle)

        XCTAssertEqual(localize.string("items", count: 1), "1 item")
        XCTAssertEqual(localize.string("items", count: 5), "5 items")
        XCTAssertEqual(localize.string("items", count: 0), "0 items")
        XCTAssertEqual(localize.string("inbox", ["name": "Ann"], count: 1), "Ann has 1 message")
        XCTAssertEqual(localize.string("inbox", ["name": "Ann"], count: 4), "Ann has 4 messages")
        XCTAssertEqual(localize.string("survivors", ["name": "Ann"], count: 1), "Ann has one survivor")
        XCTAssertEqual(localize.string("survivors", ["name": "Ann"], count: 2), "Ann has several survivors")
        XCTAssertEqual(localize.string("sent", ["from": "Ann", "to": "Bo"], count: 1), "Ann sent Bo 1 file")
        XCTAssertEqual(localize.string("sent", ["from": "Ann", "to": "Bo"], count: 3), "Ann sent Bo 3 files")
        XCTAssertEqual(localize.string("plain"), "Plain")
    }

    /// The plural form follows the language the bundled string is written
    /// in, whatever language the device is set to.
    func testABundledPluralFollowsTheLanguageOfItsTable() async throws {
        let bundle = try makeBundle(
            strings: [:],
            plurals: ["Localizable": [
                "items": plural("%#@value@", "value", [
                    "one": "%lld предмет",
                    "few": "%lld предмета",
                    "many": "%lld предметов",
                    "other": "%lld предмета",
                ]),
            ]],
            localization: "ru"
        )
        XCTAssertEqual(bundle.preferredLocalizations.first, "ru")
        let localize = try await localize(bundle)
        XCTAssertEqual(localize.string("items", count: 1), "1 предмет")
        XCTAssertEqual(localize.string("items", count: 3), "3 предмета")
        XCTAssertEqual(localize.string("items", count: 5), "5 предметов")
        XCTAssertEqual(localize.string("items", count: 21), "21 предмет")
    }

    /// European and Brazilian Portuguese count zero differently. A table
    /// written for one keeps its rule on a device set to the other.
    func testABundledPluralFollowsTheRegionOfItsTable() throws {
        let brazil = Locale(identifier: "pt_BR")
        let portugal = Locale(identifier: "pt_PT")
        func text(_ bundle: Bundle, _ count: Int, _ device: Locale) -> String? {
            BundledStrings.string(
                key: "files", namespace: "translation", bundle: bundle, arguments: [:], count: count, device: device
            )
        }

        let european = try makeBundle(
            strings: [:],
            plurals: ["Localizable": [
                "files": plural("%#@value@", "value", ["one": "%lld ficheiro", "other": "%lld ficheiros"]),
            ]],
            localization: "pt-PT"
        )
        XCTAssertEqual(european.preferredLocalizations.first, "pt-PT")
        XCTAssertEqual(text(european, 0, brazil), "0 ficheiros")
        XCTAssertEqual(text(european, 1, brazil), "1 ficheiro")
        XCTAssertEqual(text(european, 0, portugal), "0 ficheiros")
        XCTAssertEqual(BundledStrings.formatLocale(of: european, device: brazil).identifier, "pt-PT")
        XCTAssertEqual(BundledStrings.formatLocale(of: european, device: portugal), portugal)

        let brazilian = try makeBundle(
            strings: [:],
            plurals: ["Localizable": [
                "files": plural("%#@value@", "value", ["one": "%lld arquivo", "other": "%lld arquivos"]),
            ]],
            localization: "pt"
        )
        XCTAssertEqual(text(brazilian, 0, portugal), "0 arquivo")
        XCTAssertEqual(text(brazilian, 0, brazil), "0 arquivo")
        XCTAssertEqual(text(brazilian, 2, portugal), "2 arquivos")

        // Regions that count alike: the device's locale, and with it the
        // region's way of writing numbers.
        let british = try makeBundle(strings: ["Localizable": ["a": "A"]], localization: "en-GB")
        let finland = Locale(identifier: "en_FI")
        XCTAssertEqual(BundledStrings.formatLocale(of: british, device: finland), finland)
        XCTAssertEqual(BundledStrings.formatLocale(of: british, device: brazil).identifier, "en-GB")
    }

    // MARK: The user's language first

    /// A text the app shipped with in the user's language is shown before
    /// the release's text in the fallback language.
    func testABundledStringInTheUsersLanguageWinsOverTheReleasesFallbackLanguage() async throws {
        let bundle = try makeBundle(tables: [
            "et": ["title": "Pealkiri (bundled)", "both": "bundled et"],
            "en": ["title": "Title (bundled)", "both": "bundled en"],
        ])
        let localize = try await loaded(
            [
                "et/translation": ["both": "published et"],
                "en/translation": ["title": "Title", "both": "published en", "english.only": "English only"],
            ],
            locale: "et",
            fallback: "en",
            bundle: bundle
        )
        XCTAssertEqual(localize.string("title"), "Pealkiri (bundled)")
        // The release still wins where it has the key in the user's language.
        XCTAssertEqual(localize.string("both"), "published et")
        // A key nobody has in the user's language comes from the fallback one.
        XCTAssertEqual(localize.string("english.only"), "English only")
    }

    /// A bundle without the user's language does not come before the
    /// release: its strings are in another language, and the release's are
    /// the newer ones.
    func testABundledStringInAnotherLanguageStaysBehindTheRelease() async throws {
        let bundle = try makeBundle(tables: ["en": ["title": "Title (bundled)", "bundled.only": "Bundled only"]])
        let localize = try await loaded(
            ["et/translation": [:], "en/translation": ["title": "Title"]],
            locale: "et",
            fallback: "en",
            bundle: bundle
        )
        XCTAssertEqual(localize.string("title"), "Title")
        XCTAssertEqual(localize.string("bundled.only"), "Bundled only")
    }

    /// The user's language is the one the app asked for, whatever language
    /// iOS reads the bundle in.
    func testBundledStringsAreReadInTheLocaleAskedFor() throws {
        let bundle = try makeBundle(tables: [
            "fi": ["title": "Otsikko"],
            "ja": ["title": "タイトル"],
        ])
        for (locale, expected) in [("fi", "Otsikko"), ("ja", "タイトル"), ("fi-FI", "Otsikko")] {
            let localize = Localize(configuration: configuration(locale: locale, bundle: bundle))
            XCTAssertEqual(localize.string("title"), expected, locale)
        }
    }

    func testWhichLocalizationsAreInTheUsersLanguage() throws {
        func names(_ localizations: [String], _ locale: String) throws -> [String] {
            let bundle = try makeBundle(tables: Dictionary(uniqueKeysWithValues: localizations.map { ($0, ["a": "A"]) }))
            return BundledStrings.localizations(of: bundle, for: locale).map(\.name)
        }
        XCTAssertEqual(try names(["en", "et"], "et"), ["et"])
        XCTAssertEqual(try names(["en", "et"], "et-EE"), ["et"])
        XCTAssertEqual(try names(["en"], "et"), [])
        // A regional locale reads the region's table, then the language's.
        XCTAssertEqual(try names(["en", "en-GB"], "en-FI"), ["en-GB", "en"])
        XCTAssertEqual(try names(["pt-BR", "en"], "pt-PT"), ["pt-BR"])
        // Another script is another language to a reader.
        XCTAssertEqual(try names(["zh-Hans", "en"], "zh-Hant"), [])
        XCTAssertEqual(try names(["zh-Hans", "en"], "zh-TW"), [])
        XCTAssertEqual(try names(["zh-Hant", "en"], "zh-HK"), ["zh-Hant"])
        XCTAssertEqual(try names(["sr-Latn", "en"], "sr"), [])
        // Also when the script is not named, and the bundle has nothing else
        // for the system to answer with.
        XCTAssertEqual(try names(["zh-Hans"], "zh-TW"), [])
        XCTAssertEqual(try names(["zh-CN"], "zh-Hant"), [])
        XCTAssertEqual(try names(["zh-TW"], "zh-Hant"), ["zh-TW"])
        XCTAssertEqual(try names(["sr-Latn"], "sr"), [])
        XCTAssertEqual(try names(["fr"], "es"), [])
        // A localization in the user's script is found behind one that is
        // not, which the system would rank first.
        XCTAssertEqual(try names(["sr-ME", "sr-Cyrl-ME", "en"], "sr-RS"), ["sr-Cyrl-ME"])
        // Nastaliq is a style of the Arabic script, not another script.
        XCTAssertEqual(try names(["en", "ur"], "ur-Arab"), ["ur"])
        XCTAssertEqual(try names(["en", "ur-Arab"], "ur"), ["ur-Arab"])
        XCTAssertEqual(try names(["pa-Arab", "en"], "pa-PK"), ["pa-Arab"])
        XCTAssertEqual(try names(["pa-Arab", "en"], "pa"), [])
        // A script the code names counts wherever it stands in the code.
        XCTAssertEqual(try names(["zh-Hant", "en"], "zh-yue-Hans"), [])
        XCTAssertEqual(try names(["zh-Hans", "zh-Hant"], "zh-yue-Hans"), ["zh-Hans"])
        XCTAssertEqual(try names(["zh-Hans", "zh-Hant"], "zh-cmn-Hant-TW"), ["zh-Hant"])
        // Old and new spellings of one language.
        XCTAssertEqual(try names(["he", "en"], "iw"), ["he"])
        XCTAssertEqual(try names(["nb", "en"], "no"), ["nb"])
        XCTAssertEqual(try names(["no", "en"], "nb"), ["no"])
    }

    /// Before iOS 16 the system does not say which script a locale is
    /// written in when the code does not name it. A script named on one side
    /// only is then not known to be the other side's.
    func testAScriptThatCannotBeToldIsNotTakenForTheSame() throws {
        func names(_ localizations: [String], _ locale: String) throws -> [String] {
            let bundle = try makeBundle(tables: Dictionary(uniqueKeysWithValues: localizations.map { ($0, ["a": "A"]) }))
            return BundledStrings.localizations(of: bundle, for: locale, systemScripts: false).map(\.name)
        }
        XCTAssertEqual(try names(["sr-Latn", "en"], "sr"), [])
        XCTAssertEqual(try names(["sr", "en"], "sr-Latn"), [])
        XCTAssertEqual(try names(["sr-Latn", "sr-Cyrl"], "sr-Latn-RS"), ["sr-Latn"])
        XCTAssertEqual(try names(["en", "et"], "et-EE"), ["et"])
        XCTAssertEqual(try names(["en", "en-GB"], "en-FI"), ["en-GB", "en"])
        // Chinese regions are known everywhere.
        XCTAssertEqual(try names(["zh-Hans"], "zh-TW"), [])
        XCTAssertEqual(try names(["zh-Hant", "en"], "zh-HK"), ["zh-Hant"])
        XCTAssertEqual(try names(["zh-CN"], "zh-Hans"), ["zh-CN"])
    }

    /// A region's table usually holds only what differs from the language's.
    func testARegionalTableInheritsFromTheLanguagesTable() throws {
        let bundle = try makeBundle(tables: [
            "en-GB": ["colour": "Colour"],
            "en": ["colour": "Color", "title": "Title"],
        ])
        let localize = Localize(configuration: configuration(locale: "en-GB", bundle: bundle))
        XCTAssertEqual(localize.string("colour"), "Colour")
        XCTAssertEqual(localize.string("title"), "Title")
    }

    /// The namespace's table is read in every localization of the language
    /// before the default table of any.
    func testARegionsDefaultTableDoesNotAnswerForTheNamespacesTable() throws {
        let bundle = try makeBundle(localizations: [
            "en-GB": (["Localizable": ["title": "Default title (GB)", "default.only": "Default only (GB)"]], [:]),
            "en": (["checkout": ["title": "Checkout title"], "Localizable": ["title": "Default title"]], [:]),
        ])
        let localize = Localize(
            configuration: configuration(locale: "en-GB", namespaces: ["checkout"], bundle: bundle)
        )
        XCTAssertEqual(localize.string("title"), "Checkout title")
        XCTAssertEqual(localize.string("default.only"), "Default only (GB)")
    }

    /// `Base.lproj` holds strings in the app's development language.
    func testStringsInTheBaseFolderAreInTheDevelopmentLanguage() async throws {
        let bundle = try makeBundle(
            localizations: [
                "Base": (["Localizable": ["title": "Заголовок"]], [:]),
                "en": (["Localizable": ["title": "Title (bundled)"]], [:]),
            ],
            developmentRegion: "ru"
        )
        XCTAssertEqual(BundledStrings.localizations(of: bundle, for: "ru").map(\.name), ["ru"])
        XCTAssertEqual(BundledStrings.localizations(of: bundle, for: "uk").map(\.name), [])
        let localize = try await loaded(
            ["ru/translation": [:], "en/translation": ["title": "Title"]],
            locale: "ru",
            fallback: "en",
            bundle: bundle
        )
        XCTAssertEqual(localize.string("title"), "Заголовок")
    }

    /// A bundled plural in the user's language counts by that language's
    /// rule, and comes before the fallback language's published forms.
    func testABundledPluralInTheUsersLanguageWinsOverTheReleasesFallbackLanguage() async throws {
        let bundle = try makeBundle(localizations: [
            "ru": ([:], ["Localizable": [
                "items": plural("%#@value@", "value", [
                    "one": "%lld предмет",
                    "few": "%lld предмета",
                    "many": "%lld предметов",
                    "other": "%lld предмета",
                ]),
            ]]),
            "en": (["Localizable": ["plain": "Plain"]], [:]),
        ])
        let localize = try await loaded(
            [
                "ru/translation": [:],
                "en/translation": ["items_one": "{{count}} item", "items_other": "{{count}} items"],
            ],
            locale: "ru",
            fallback: "en",
            bundle: bundle
        )
        XCTAssertEqual(localize.string("items", count: 1), "1 предмет")
        XCTAssertEqual(localize.string("items", count: 3), "3 предмета")
        XCTAssertEqual(localize.string("items", count: 5), "5 предметов")
    }

    /// The release's general form stands in for a missing one only as a last
    /// resort. A bundled string in the user's language that has the right
    /// form is not that far down.
    func testABundledPluralInTheUsersLanguageWinsOverTheReleasesGeneralForm() async throws {
        let bundle = try makeBundle(
            strings: [:],
            plurals: ["Localizable": [
                "items": plural("%#@value@", "value", ["one": "%lld item", "other": "%lld items"]),
            ]]
        )
        let localize = try await localize(bundle, release: ["items_other": "{{count}} published items"])
        XCTAssertEqual(localize.string("items", count: 1), "1 item")
        XCTAssertEqual(localize.string("items", count: 6), "6 published items")
    }

    func testAPublishedPluralWinsOverTheBundledOne() async throws {
        let bundle = try makeBundle(
            strings: [:],
            plurals: ["Localizable": [
                "items": plural("%#@value@", "value", ["one": "%lld item", "other": "%lld items"]),
            ]]
        )
        let localize = try await localize(bundle, release: [
            "items_one": "{{count}} published item",
            "items_other": "{{count}} published items",
        ])
        XCTAssertEqual(localize.string("items", count: 1), "1 published item")
        XCTAssertEqual(localize.string("items", count: 6), "6 published items")
        XCTAssertEqual(localize.string("other", count: 6), "other")
    }
}

final class PrintfFormatTests: XCTestCase {
    func testConversionsItReads() {
        XCTAssertEqual(PrintfFormat.arguments(of: "No conversions, 100%% sure"), [:])
        XCTAssertEqual(PrintfFormat.arguments(of: "%@"), [1: .object])
        XCTAssertEqual(PrintfFormat.arguments(of: "%@ and %@ and %lld"), [1: .object, 2: .object, 3: .int64])
        XCTAssertEqual(PrintfFormat.arguments(of: "%2$@ then %1$lld then %2$@"), [1: .int64, 2: .object])
        XCTAssertEqual(PrintfFormat.arguments(of: "%d %i %u %hd %x %X %o"), [
            1: .int32, 2: .int32, 3: .int32, 4: .int32, 5: .int32, 6: .int32, 7: .int32,
        ])
        XCTAssertEqual(PrintfFormat.arguments(of: "%ld %zu %td %lu"), [1: .int, 2: .int, 3: .int, 4: .int])
        XCTAssertEqual(PrintfFormat.arguments(of: "%lld %llu %qd %jd"), [1: .int64, 2: .int64, 3: .int64, 4: .int64])
        XCTAssertEqual(PrintfFormat.arguments(of: "%f %.2f %5.1lf %e %g %+08.3f"), [
            1: .double, 2: .double, 3: .double, 4: .double, 5: .double, 6: .double,
        ])
        XCTAssertEqual(PrintfFormat.arguments(of: "%05d|%-5d|% d|%#x"), [1: .int32, 2: .int32, 3: .int32, 4: .int32])
        XCTAssertEqual(PrintfFormat.arguments(of: "%#@value@"), [1: .pluralRule])
        XCTAssertEqual(PrintfFormat.arguments(of: "%2$#@count@"), [2: .pluralRule])
        XCTAssertEqual(PrintfFormat.arguments(of: "%1$@ of %#@files@"), nil, "numbered and unnumbered are mixed")
        XCTAssertEqual(PrintfFormat.arguments(of: "%1$@ of %2$#@files@"), [1: .object, 2: .pluralRule])
        XCTAssertEqual(PrintfFormat.arguments(of: "%3$@"), [3: .object])
    }

    func testConversionsItRefuses() {
        let refused = [
            "%s", "%S", "%c", "%C", "%p", "%n", "%*d", "%.*f", "%Lf", "%hhd extra %", "%", "abc %",
            "%1$@ %@", "%@ %1$@", "%1$@ %1$d", "%0$@", "%33$@", "%999999999999999999999$@", "%5@", "%-@", "%l@",
            "%#@", "%#@@", "%#@open", "%y", "%é", "% ", "%1$", "%lll d", "%hlf",
        ]
        for format in refused {
            XCTAssertNil(PrintfFormat.arguments(of: format), format)
        }
    }

    func testFillNeverCrashesOnOddFormats() {
        let formats = [
            "%", "%%", "%%%", "%@%", "%1$@%2$@%3$@%4$@", "%@%@%@%@%@", "%lld%lld", "%#@a@%#@b@", "%1$#@a@",
            "%32$@", "%d%@%f", "{{", "{{}}%@", "%@{{name}}",
        ]
        for format in formats {
            _ = BundledStrings.fill(format, arguments: ["name": "Ann", "n": 3], count: 2)
            _ = BundledStrings.fill(format, arguments: [:], count: 1)
            _ = BundledStrings.fill(format, arguments: ["x": Optional<Int>.none as Any], count: nil)
        }
    }
}
