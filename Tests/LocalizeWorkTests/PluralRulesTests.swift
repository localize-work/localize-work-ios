import XCTest
@testable import LocalizeWork

final class PluralRulesTests: XCTestCase {
    private func assertCategories(
        _ locales: String,
        _ expected: [(ClosedRange<Int>, PluralCategory)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for locale in locales.split(separator: " ").map(String.init) {
            for (counts, category) in expected {
                for count in counts {
                    XCTAssertEqual(
                        PluralRules.category(for: count, locale: locale), category,
                        "\(locale) \(count)", file: file, line: line
                    )
                }
            }
        }
    }

    func testOneForOneOnly() {
        assertCategories("en de et fi sv nl da nb", [(0...0, .other), (1...1, .one), (2...30, .other)])
        assertCategories("en de et fi sv nl da nb", [(100...101, .other), (1_000_000...1_000_000, .other)])
    }

    func testRomanceLanguagesHaveManyForWholeMillions() {
        assertCategories("fr", [(0...1, .one), (2...2, .other), (1_000_000...1_000_000, .many)])
        assertCategories("es it", [(0...0, .other), (1...1, .one), (2...2, .other), (1_000_000...1_000_000, .many)])
        assertCategories("fr es it", [(2_000_000...2_000_000, .many), (1_000_001...1_000_001, .other)])
        // Brazilian Portuguese counts 0 as one; European Portuguese does not.
        assertCategories("pt pt-BR", [(0...1, .one), (2...2, .other), (1_000_000...1_000_000, .many)])
        assertCategories("pt-PT pt_PT", [(0...0, .other), (1...1, .one), (1_000_000...1_000_000, .many)])
    }

    func testRussianAndUkrainian() {
        assertCategories("ru uk", [
            (1...1, .one), (2...4, .few), (5...20, .many), (21...21, .one), (22...22, .few),
            (11...14, .many), (0...0, .many), (101...101, .one), (111...111, .many),
        ])
    }

    func testPolish() {
        assertCategories("pl", [
            (1...1, .one), (2...4, .few), (5...5, .many), (12...12, .many), (22...22, .few),
            (21...21, .many), (0...0, .many),
        ])
    }

    func testCzechAndSlovak() {
        assertCategories("cs sk", [(1...1, .one), (2...4, .few), (5...5, .other), (0...0, .other)])
    }

    func testLithuanian() {
        assertCategories("lt", [(1...1, .one), (2...9, .few), (11...19, .other), (21...21, .one), (10...10, .other)])
    }

    func testLatvian() {
        assertCategories("lv", [(0...0, .zero), (1...1, .one), (11...11, .zero), (21...21, .one), (2...9, .other)])
    }

    func testRomanian() {
        assertCategories("ro", [(1...1, .one), (0...0, .few), (2...19, .few), (20...20, .other), (101...101, .few)])
    }

    func testSlovenian() {
        assertCategories("sl", [(1...1, .one), (2...2, .two), (3...4, .few), (5...5, .other), (101...101, .one)])
    }

    func testArabic() {
        assertCategories("ar", [
            (0...0, .zero), (1...1, .one), (2...2, .two), (3...10, .few), (11...99, .many), (100...100, .other),
            (103...103, .few),
        ])
    }

    func testHebrew() {
        assertCategories("he iw", [(1...1, .one), (2...2, .two), (3...3, .other), (0...0, .other), (20...20, .other)])
    }

    func testLanguagesWithoutPluralForms() {
        assertCategories("ja zh ko vi th id", [(0...30, .other), (1_000_000...1_000_000, .other)])
        // `und`, a locale without a language, is in CLDR's table with these.
        // It is not in the fixture: ICU answers for it by the device's language.
        assertCategories("und", [(0...30, .other), (1_000_000...1_000_000, .other)])
    }

    func testAnUnknownLanguageUsesOneAndOther() {
        assertCategories("xx tlh", [(0...0, .other), (1...1, .one), (2...100, .other)])
        assertCategories("", [(1...1, .one), (2...2, .other)])
    }

    func testTheLanguageIsReadFromTheStartOfTheLocale() {
        XCTAssertEqual(PluralRules.category(for: 5, locale: "ru-RU"), .many)
        XCTAssertEqual(PluralRules.category(for: 5, locale: "ru_UA"), .many)
        XCTAssertEqual(PluralRules.category(for: 5, locale: "RU"), .many)
        XCTAssertEqual(PluralRules.category(for: 1, locale: "zh-Hans-CN"), .other)
        XCTAssertEqual(PluralRules.category(for: 2, locale: "en-FI"), .other)
    }

    func testNegativeCountsUseTheirSize() {
        XCTAssertEqual(PluralRules.category(for: -1, locale: "en"), .one)
        XCTAssertEqual(PluralRules.category(for: -3, locale: "ru"), .few)
        XCTAssertEqual(PluralRules.category(for: Int.min, locale: "en"), .other)
    }

    /// Every language in CLDR's cardinal table, against what ICU answers.
    func testEveryLanguageAgreesWithCLDR() {
        let letters: [Character: PluralCategory] = [
            "z": .zero, "o": .one, "t": .two, "f": .few, "m": .many, "x": .other,
        ]
        var checked = 0
        for (locales, pattern) in PluralFixture.patterns {
            let expected = pattern.map { letters[$0] }
            XCTAssertEqual(expected.count, PluralFixture.samples.count)
            for locale in locales.split(separator: " ").map(String.init) {
                for (count, category) in zip(PluralFixture.samples, expected) {
                    XCTAssertEqual(PluralRules.category(for: count, locale: locale), category, "\(locale) \(count)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200)
    }
}
