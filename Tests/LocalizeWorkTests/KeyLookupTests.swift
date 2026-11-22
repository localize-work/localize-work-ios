import XCTest
@testable import LocalizeWork

final class KeyLookupTests: XCTestCase {
    func testDotsWalkNestedObjects() {
        let file = publishedFile(#"{ "nav": { "home": "Home", "menu": { "close": "Close" } }, "title": "Title" }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "title"), "Title")
        XCTAssertEqual(KeyLookup.string(in: file, key: "nav.home"), "Home")
        XCTAssertEqual(KeyLookup.string(in: file, key: "nav.menu.close"), "Close")
    }

    /// A name can begin with a combining mark, which a character-wise split
    /// would leave attached to the dot before it.
    func testAKeyIsSplitAtItsDots() {
        let file = publishedFile("{ \"a\": { \"\u{301}b\": \"accent\" } }")
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.\u{301}b"), "accent")
    }

    func testAMissingKeyIsNotFound() {
        let file = publishedFile(#"{ "nav": { "home": "Home" } }"#)
        XCTAssertNil(KeyLookup.string(in: file, key: "nav.away"))
        XCTAssertNil(KeyLookup.string(in: file, key: "other"))
        XCTAssertNil(KeyLookup.string(in: file, key: "nav.home.deeper"))
        XCTAssertNil(KeyLookup.string(in: file, key: ""))
        XCTAssertNil(KeyLookup.string(in: [:], key: "nav.home"))
    }

    func testAGroupOfKeysIsNotAText() {
        let file = publishedFile(#"{ "nav": { "home": "Home" } }"#)
        XCTAssertNil(KeyLookup.string(in: file, key: "nav"))
    }

    /// Keys `a` and `a.b`: the publisher keeps `a` in place and writes `a.b`
    /// at the top level under its full dotted name.
    func testADeeperKeyWrittenAtTheTopLevelUnderItsDottedName() {
        let file = publishedFile(#"{ "a": "shallow", "a.b": "deep", "a.b.c": "deeper" }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "a"), "shallow")
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b"), "deep")
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b.c"), "deeper")
        XCTAssertNil(KeyLookup.string(in: file, key: "a.c"))
    }

    /// A locale that lacks the text `a` still gets `a.b` at the top level.
    func testADottedNameWithoutTheTextItRunsThrough() {
        let file = publishedFile(#"{ "a.b": "deep", "other": { "x": "X" } }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b"), "deep")
        XCTAssertNil(KeyLookup.string(in: file, key: "a"))
    }

    func testRemainingSegmentsAreJoinedAtEachLevel() {
        let file = publishedFile(#"{ "a": { "b": "text", "b.c": "below", "x.y": { "z": "nested again" } } }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b"), "text")
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b.c"), "below")
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.x.y.z"), "nested again")
    }

    func testAnEmptyTextIsAValue() {
        let file = publishedFile(#"{ "empty": "", "nav": { "blank": "" } }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "empty"), "")
        XCTAssertEqual(KeyLookup.string(in: file, key: "nav.blank"), "")
    }

    /// An empty `a.b.c` under a text `a.b` is written next to that text.
    func testAnEmptyTextWrittenNextToTheTextAboveIt() {
        let file = publishedFile(#"{ "a": { "b": "text", "b.c": "" } }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b.c"), "")
        XCTAssertEqual(KeyLookup.string(in: file, key: "a.b"), "text")
    }

    /// `b.b` at the top level must not answer `b.b.b`, and a text must not
    /// answer a key below it.
    func testATextDoesNotAnswerALongerKey() {
        let file = publishedFile(#"{ "b": "text", "b.b": "x", "form": "f", "form.password": "pw" }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: "b.b"), "x")
        XCTAssertNil(KeyLookup.string(in: file, key: "b.b.b"))
        XCTAssertNil(KeyLookup.string(in: file, key: "form.password.0"))
        XCTAssertNil(KeyLookup.string(in: file, key: "form.password.length"))
    }

    func testEmptySegmentsAreKeptAsWritten() {
        let file = publishedFile(#"{ "": { "leading": "L" }, "trailing": { "": "T" } }"#)
        XCTAssertEqual(KeyLookup.string(in: file, key: ".leading"), "L")
        XCTAssertEqual(KeyLookup.string(in: file, key: "trailing."), "T")
    }

    func testValuesThatAreNotTextsAreNotFound() {
        let file = publishedFile(#"{ "number": 5, "flag": true, "nothing": null, "list": ["x"], "in": { "number": 1 } }"#)
        for key in ["number", "flag", "nothing", "list", "in.number", "list.0", "number.x"] {
            XCTAssertNil(KeyLookup.string(in: file, key: key), key)
        }
    }

    func testPluralCandidates() {
        // As i18next: the zero form for 0, the count's own form, the plain
        // key. No other form of the same file stands in for a missing one.
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: nil, locale: "en"), ["items"])
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: 1, locale: "en"), ["items_one", "items"])
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: 5, locale: "en"), ["items_other", "items"])
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: 0, locale: "en"), ["items_zero", "items_other", "items"])
        XCTAssertEqual(KeyLookup.candidates(key: "a.items", count: 3, locale: "ru"), ["a.items_few", "a.items"])
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: 0, locale: "ru"), ["items_zero", "items_many", "items"])
        // Latvian and Arabic name 0 "zero" themselves.
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: 0, locale: "lv"), ["items_zero", "items"])
        XCTAssertEqual(KeyLookup.candidates(key: "items", count: 0, locale: "ar"), ["items_zero", "items"])
    }
}

final class LocaleCodeTests: XCTestCase {
    func testChain() {
        XCTAssertEqual(LocaleCode.chain(locale: "en-FI", fallback: "et"), ["en-FI", "en", "et"])
        XCTAssertEqual(LocaleCode.chain(locale: "en-FI", fallback: "en"), ["en-FI", "en"])
        XCTAssertEqual(LocaleCode.chain(locale: "en-FI", fallback: "en-FI"), ["en-FI", "en"])
        XCTAssertEqual(LocaleCode.chain(locale: "en", fallback: nil), ["en"])
        XCTAssertEqual(LocaleCode.chain(locale: "en", fallback: "en"), ["en"])
        XCTAssertEqual(LocaleCode.chain(locale: "zh-Hans-CN", fallback: "en"), ["zh-Hans-CN", "zh-Hans", "zh", "en"])
        // The fallback locale brings its shorter forms too.
        XCTAssertEqual(LocaleCode.chain(locale: "et", fallback: "pt-BR"), ["et", "pt-BR", "pt"])
        XCTAssertEqual(LocaleCode.chain(locale: "en-FI", fallback: "en-GB"), ["en-FI", "en", "en-GB"])
        XCTAssertEqual(LocaleCode.chain(locale: "", fallback: nil), [])
    }

    func testCanonicalForm() {
        XCTAssertEqual(LocaleCode.canonical("en-fi"), "en-FI")
        XCTAssertEqual(LocaleCode.canonical("EN_fi"), "en-FI")
        XCTAssertEqual(LocaleCode.canonical("zh-hans-cn"), "zh-Hans-CN")
        XCTAssertEqual(LocaleCode.canonical("es-419"), "es-419")
        XCTAssertEqual(LocaleCode.canonical(" et "), "et")
        XCTAssertEqual(LocaleCode.canonical(""), "")
        // Codes older systems still report are written as the project writes them.
        XCTAssertEqual(LocaleCode.canonical("iw-IL"), "he-IL")
        XCTAssertEqual(LocaleCode.canonical("in"), "id")
        XCTAssertEqual(LocaleCode.canonical("ji"), "yi")
        // What a device adds after the region is not part of a published locale.
        XCTAssertEqual(LocaleCode.canonical("en-FI-u-ca-gregory"), "en-FI")
        XCTAssertEqual(LocaleCode.canonical("de-CH-1996"), "de-CH-1996")
        // Anything else is taken as written.
        XCTAssertEqual(LocaleCode.canonical("no"), "no")
    }

    func testConfigurationNormalisesItsLocales() {
        var configuration = LocalizeConfiguration(projectSlug: "demo", locale: "en_fi", fallbackLocale: "ET")
        XCTAssertEqual(configuration.locale, "en-FI")
        XCTAssertEqual(configuration.fallbackLocale, "et")
        XCTAssertEqual(configuration.localeChain, ["en-FI", "en", "et"])
        configuration.locale = "pt_br"
        XCTAssertEqual(configuration.localeChain, ["pt-BR", "pt", "et"])
    }

    func testConfigurationDefaults() {
        let configuration = LocalizeConfiguration(projectSlug: "demo")
        XCTAssertEqual(configuration.cdnBaseURL.absoluteString, "https://cdn.localize.work")
        XCTAssertEqual(configuration.namespaces, ["translation"])
        XCTAssertEqual(configuration.defaultNamespace, "translation")
        XCTAssertEqual(configuration.updatePolicy, .immediately)
        XCTAssertNil(configuration.version)
        XCTAssertNil(configuration.fallbackLocale)
        XCTAssertEqual(configuration.locale, LocaleCode.canonical(Locale.preferredLanguages.first ?? "en"))
        XCTAssertEqual(
            LocalizeConfiguration(projectSlug: "demo", namespaces: ["common", "checkout"]).defaultNamespace,
            "common"
        )
    }
}
