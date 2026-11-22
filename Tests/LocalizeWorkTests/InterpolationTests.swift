import XCTest
@testable import LocalizeWork

final class InterpolationTests: XCTestCase {
    private func fill(_ text: String, _ values: [String: String] = [:]) -> String {
        Interpolation.apply(text) { values[$0] }
    }

    func testNamedValues() {
        XCTAssertEqual(fill("Hello, {{name}}!", ["name": "Ann"]), "Hello, Ann!")
        XCTAssertEqual(fill("{{a}}{{b}}", ["a": "1", "b": "2"]), "12")
        XCTAssertEqual(fill("{{name}}, meet {{name}}", ["name": "Ann"]), "Ann, meet Ann")
        XCTAssertEqual(fill("No placeholders"), "No placeholders")
        XCTAssertEqual(fill(""), "")
    }

    func testSpacesInsideTheBraces() {
        XCTAssertEqual(fill("{{ name }} and {{  name}} and {{name  }}", ["name": "Ann"]), "Ann and Ann and Ann")
    }

    func testAFormatNameIsIgnored() {
        XCTAssertEqual(fill("Total: {{price, currency}}", ["price": "5"]), "Total: 5")
        XCTAssertEqual(fill("{{ date , datetime(short) }}", ["date": "today"]), "today")
    }

    func testTheUnescapedMarkerIsAccepted() {
        XCTAssertEqual(fill("{{- html}} and {{-html}}", ["html": "<b>"]), "<b> and <b>")
    }

    func testAnUnknownVariableIsLeftAsWritten() {
        XCTAssertEqual(fill("Hi {{who}}, {{name}}", ["name": "Ann"]), "Hi {{who}}, Ann")
        XCTAssertEqual(fill("{{ who , format }}"), "{{ who , format }}")
    }

    func testValuesAreNotEscapedOrReadAgain() {
        XCTAssertEqual(fill("{{name}}", ["name": "<A & B>"]), "<A & B>")
        XCTAssertEqual(fill("{{a}} {{b}}", ["a": "{{b}}", "b": "B"]), "{{b}} B")
    }

    func testNestingIsNotResolved() {
        XCTAssertEqual(fill("See $t(other.key) and {{name}}", ["name": "Ann"]), "See $t(other.key) and Ann")
    }

    func testBracesThatAreNotPlaceholders() {
        XCTAssertEqual(fill("{{}}"), "{{}}")
        XCTAssertEqual(fill("{{ , x}}"), "{{ , x}}")
        XCTAssertEqual(fill("{{-}}"), "{{-}}")
        XCTAssertEqual(fill("{{name", ["name": "Ann"]), "{{name")
        XCTAssertEqual(fill("name}}", ["name": "Ann"]), "name}}")
        XCTAssertEqual(fill("{{a}b}}", ["a": "1", "a}b": "2"]), "{{a}b}}")
        XCTAssertEqual(fill("{ {name} }", ["name": "Ann"]), "{ {name} }")
        XCTAssertEqual(fill("{{{name}}}", ["name": "Ann"]), "{Ann}")
        XCTAssertEqual(fill("{{ {{name}} }}", ["name": "Ann"]), "{{ Ann }}")
        XCTAssertEqual(fill("{{{{{{{{", ["name": "Ann"]), "{{{{{{{{")
        XCTAssertEqual(fill("{{{{{{{{ {{name}}", ["name": "Ann"]), "{{{{{{{{ Ann")
    }

    func testHasPlaceholder() {
        XCTAssertTrue(Interpolation.hasPlaceholder("Hello, {{name}}!"))
        XCTAssertFalse(Interpolation.hasPlaceholder("Hello, %@!"))
        XCTAssertFalse(Interpolation.hasPlaceholder("{{}}"))
    }

    func testValuesAsText() {
        XCTAssertEqual(LocalizeArguments.text("Ann"), "Ann")
        XCTAssertEqual(LocalizeArguments.text(3), "3")
        XCTAssertEqual(LocalizeArguments.text(1.5), "1.5")
        XCTAssertEqual(LocalizeArguments.text(true), "true")
        XCTAssertEqual(LocalizeArguments.text(Optional("Ann") as Any), "Ann")
        XCTAssertEqual(LocalizeArguments.text(Optional<String>.none as Any), "")
        XCTAssertEqual(LocalizeArguments.text("Ann".dropFirst()), "nn")
    }
}

/// Lookups through the public API, on a downloaded release.
final class LookupTests: LocalizeTestCase {
    func testNestedKeysAndNamespaces() async throws {
        let localize = try await loaded(
            [
                "en/common": ["nav": ["home": "Home"]],
                "en/checkout": ["pay": "Pay now"],
            ],
            namespaces: ["common", "checkout"]
        )
        XCTAssertEqual(localize.string("nav.home"), "Home")
        XCTAssertEqual(localize.string("pay", namespace: "checkout"), "Pay now")
        // A key of another namespace is not found in the default one.
        XCTAssertEqual(localize.string("pay"), "pay")
        XCTAssertEqual(localize.string("nav.home", namespace: "unknown"), "nav.home")
    }

    func testTheDefaultNamespaceCanBeChosen() async throws {
        stub.setPointer("v1")
        stub.publish("v1", ["en/common": ["a": "common"], "en/checkout": ["a": "checkout"]])
        let localize = Localize(
            configuration: configuration(namespaces: ["common", "checkout"], defaultNamespace: "checkout")
        )
        try await localize.refresh()
        XCTAssertEqual(localize.string("a"), "checkout")
        XCTAssertEqual(localize.string("a", namespace: "common"), "common")
    }

    func testTheTopLevelDottedNameConflictCase() async throws {
        let localize = try await loaded(["en/translation": ["a": "shallow", "a.b": "deep"]])
        XCTAssertEqual(localize.string("a"), "shallow")
        XCTAssertEqual(localize.string("a.b"), "deep")
    }

    func testAMissingKeyFallsThroughTheLocaleChain() async throws {
        let localize = try await loaded(
            [
                "en-FI/translation": ["greeting": "Moi"],
                "en/translation": ["greeting": "Hello", "bye": "Bye"],
                "et/translation": ["greeting": "Tere", "bye": "Head aega", "only": "Ainult"],
            ],
            locale: "en-FI",
            fallback: "et"
        )
        XCTAssertEqual(localize.string("greeting"), "Moi")
        XCTAssertEqual(localize.string("bye"), "Bye")
        XCTAssertEqual(localize.string("only"), "Ainult")
        XCTAssertEqual(localize.string("nowhere"), "nowhere")
    }

    func testAnEmptyTextInABaseLocaleIsAValue() async throws {
        let localize = try await loaded(
            [
                "en/translation": ["empty": "", "group": ["blank": ""]],
                "et/translation": ["empty": "Tühi", "group": ["blank": "Tühi"]],
            ],
            locale: "en-FI",
            fallback: "et"
        )
        XCTAssertEqual(localize.string("empty"), "")
        XCTAssertEqual(localize.string("group.blank"), "")
        XCTAssertEqual(localize.string("empty", fallback: "fallback"), "")
    }

    func testAGroupInOneLocaleFallsThroughToATextInTheNext() async throws {
        let localize = try await loaded(
            ["en/translation": ["a": ["b": "group"]], "et/translation": ["a": "tekst"]],
            fallback: "et"
        )
        XCTAssertEqual(localize.string("a"), "tekst")
    }

    func testTheCallersFallbackAndTheKeyItself() async throws {
        let localize = try await loaded(["en/translation": ["a": "A"]])
        XCTAssertEqual(localize.string("missing.key", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(localize.string("missing.key", ["name": "Ann"], fallback: "Hi {{name}}"), "Hi Ann")
        XCTAssertEqual(localize.string("missing.key"), "missing.key")
        XCTAssertEqual(localize.string("missing {{name}}", ["name": "Ann"]), "missing {{name}}")
    }

    func testPluralForms() async throws {
        let localize = try await loaded([
            "en/translation": [
                "items_one": "{{count}} item",
                "items_other": "{{count}} items",
                "files_zero": "No files",
                "files_one": "One file",
                "files_other": "{{count}} files",
                "nested": ["docs_one": "a doc", "docs_other": "docs"],
                "plain": "{{count}} things",
                "onlyOther_other": "{{count}} of them",
            ],
        ])
        XCTAssertEqual(localize.string("items", count: 1), "1 item")
        XCTAssertEqual(localize.string("items", count: 2), "2 items")
        XCTAssertEqual(localize.string("items", count: 0), "0 items")
        XCTAssertEqual(localize.string("items", count: -1), "-1 item")
        XCTAssertEqual(localize.string("files", count: 0), "No files")
        XCTAssertEqual(localize.string("files", count: 1), "One file")
        XCTAssertEqual(localize.string("files", count: 12), "12 files")
        XCTAssertEqual(localize.string("nested.docs", count: 1), "a doc")
        XCTAssertEqual(localize.string("nested.docs", count: 3), "docs")
        // No plural forms: the plain key answers.
        XCTAssertEqual(localize.string("plain", count: 3), "3 things")
        // No locale has the form of the count: the general form is the last resort.
        XCTAssertEqual(localize.string("onlyOther", count: 1), "1 of them")
        // Without a count a plural key has no text of its own.
        XCTAssertEqual(localize.string("items"), "items")
    }

    func testPluralFormsOfALanguageWithMoreCategories() async throws {
        let localize = try await loaded(
            [
                "ru/translation": [
                    "items_one": "{{count}} предмет",
                    "items_few": "{{count}} предмета",
                    "items_many": "{{count}} предметов",
                    "items_other": "{{count}} предмета",
                ],
            ],
            locale: "ru"
        )
        XCTAssertEqual(localize.string("items", count: 1), "1 предмет")
        XCTAssertEqual(localize.string("items", count: 3), "3 предмета")
        XCTAssertEqual(localize.string("items", count: 5), "5 предметов")
        XCTAssertEqual(localize.string("items", count: 21), "21 предмет")
        XCTAssertEqual(localize.string("items", count: 112), "112 предметов")
    }

    /// The category comes from the language of the file being read, not
    /// from the language the app is shown in.
    func testThePluralCategoryFollowsTheLanguageOfEachFile() async throws {
        let localize = try await loaded(
            [
                "ru/translation": ["other_one": "ru one"],
                "en/translation": [
                    "items_one": "{{count}} item",
                    "items_other": "{{count}} items",
                ],
            ],
            locale: "ru",
            fallback: "en"
        )
        // 21 is "one" in Russian and "other" in English.
        XCTAssertEqual(localize.string("items", count: 21), "21 items")
        XCTAssertEqual(localize.string("items", count: 1), "1 item")
    }

    func testAVariantOverridesSomePluralForms() async throws {
        let localize = try await loaded(
            [
                "en-FI/translation": ["items_one": "{{count}} piece", "mixed": "plain in en-FI"],
                "en/translation": [
                    "items_one": "{{count}} item",
                    "items_other": "{{count}} items",
                    "mixed_other": "plural in en",
                ],
            ],
            locale: "en-FI"
        )
        XCTAssertEqual(localize.string("items", count: 1), "1 piece")
        XCTAssertEqual(localize.string("items", count: 4), "4 items")
        // As in i18next, every form is tried in a locale before the next one.
        XCTAssertEqual(localize.string("mixed", count: 4), "plain in en-FI")
    }

    /// A regional variant that overrides only the general form inherits the
    /// form for 1 from the base language, as in i18next.
    func testAVariantThatOverridesOnlyTheOtherFormInheritsTheRest() async throws {
        let localize = try await loaded(
            [
                "en-FI/translation": ["items_other": "{{count}} things (FI)"],
                "en/translation": ["items_one": "{{count}} item", "items_other": "{{count}} items"],
            ],
            locale: "en-FI"
        )
        XCTAssertEqual(localize.string("items", count: 1), "1 item")
        XCTAssertEqual(localize.string("items", count: 2), "2 things (FI)")
    }

    /// The same holds across languages: a form the first language lacks is
    /// taken from the fallback language before any other form stands in.
    func testAMissingFormFallsToTheNextLanguageBeforeTheOtherForm() async throws {
        let localize = try await loaded(
            [
                "de/translation": ["items_other": "{{count}} Artikel", "solo_other": "{{count}} allein"],
                "en/translation": ["items_one": "{{count}} item", "items_other": "{{count}} items"],
            ],
            locale: "de",
            fallback: "en"
        )
        XCTAssertEqual(localize.string("items", count: 1), "1 item")
        XCTAssertEqual(localize.string("items", count: 3), "3 Artikel")
        // English has nothing for this key, so German's general form is the last resort.
        XCTAssertEqual(localize.string("solo", count: 1), "1 allein")
    }

    func testInterpolation() async throws {
        let localize = try await loaded([
            "en/translation": [
                "greeting": "Hello, {{name}}!",
                "spaced": "Hello, {{ name }}!",
                "price": "Total: {{amount, currency}}",
                "unknown": "Hi {{who}}",
                "count": "You have {{count}} points",
                "inbox_one": "{{name}} has {{count}} message",
                "inbox_other": "{{name}} has {{count}} messages",
                "nesting": "$t(greeting)",
                "html": "{{value}}",
            ],
        ])
        XCTAssertEqual(localize.string("greeting", ["name": "Ann"]), "Hello, Ann!")
        XCTAssertEqual(localize.string("spaced", ["name": "Ann"]), "Hello, Ann!")
        XCTAssertEqual(localize.string("price", ["amount": 5]), "Total: 5")
        XCTAssertEqual(localize.string("unknown", ["name": "Ann"]), "Hi {{who}}")
        XCTAssertEqual(localize.string("greeting"), "Hello, {{name}}!")
        XCTAssertEqual(localize.string("count", ["count": 7]), "You have 7 points")
        XCTAssertEqual(localize.string("count", count: 7), "You have 7 points")
        XCTAssertEqual(localize.string("inbox", ["name": "Ann"], count: 1), "Ann has 1 message")
        XCTAssertEqual(localize.string("inbox", ["name": "Ann"], count: 2), "Ann has 2 messages")
        XCTAssertEqual(localize.string("nesting"), "$t(greeting)")
        XCTAssertEqual(localize.string("html", ["value": "<b>&</b>"]), "<b>&</b>")
        let dynamic = LocalizeArguments([("name", "Bo")])
        XCTAssertEqual(localize.string("greeting", dynamic), "Hello, Bo!")
    }
}
