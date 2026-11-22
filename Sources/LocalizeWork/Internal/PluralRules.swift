import Foundation

/// A CLDR plural category. The raw value is the suffix a published key
/// carries: `items_one`, `items_other`.
enum PluralCategory: String, Sendable, CaseIterable {
    case zero, one, two, few, many, other
}

/// CLDR cardinal plural rules for whole numbers.
///
/// Foundation has no public API that names the plural category of a number,
/// so the rules are written out here, taken from CLDR 47
/// (`common/supplemental/plurals.xml`). Only whole numbers are covered, which
/// lets each rule drop its decimal operands (`v`, `f`, `t`, `e`): for a whole
/// number `i` equals `n` and the rest are zero.
enum PluralRules {
    /// The category of `count` in the language of `locale` (`"en"`, `"pt-PT"`).
    /// A language without a rule here uses `one` for 1 and `other` otherwise.
    static func category(for count: Int, locale: String) -> PluralCategory {
        family(for: locale).category(UInt64(count.magnitude))
    }

    static func family(for locale: String) -> Family {
        let code = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        // European Portuguese is the one regional rule in the cardinal table.
        if code == "pt-pt" || code.hasPrefix("pt-pt-") { return .oneAndMillions }
        let language = code.split(separator: "-").first.map(String.init) ?? ""
        return families[language] ?? .oneIsOne
    }

    /// Languages that share one rule. Named after what the rule tells apart.
    enum Family: Sendable {
        /// No plural forms: always `other`.
        case none
        /// one: 1
        case oneIsOne
        /// one: 0, 1
        case oneIsZeroOrOne
        /// one: 0, 1, 11–99
        case tachelhitCentral
        /// one: ends in 1, except 11
        case oneEndsInOne
        /// one: everything except numbers ending in 4, 6 or 9
        case filipino
        /// zero: ends in 0, or 11–19; one: ends in 1, except 11
        case latvian
        /// zero: 0; one: 1
        case zeroAndOne
        /// one: 1; two: 2
        case oneAndTwo
        /// one: 0, 1; few: 2–10
        case tachelhit
        /// one: 1; few: 0, and 2–19 in each hundred
        case romanian
        /// one: ends in 1 (not 11); few: ends in 2–4 (not 12–14)
        case serboCroatian
        /// one: 0, 1; many: whole millions
        case zeroOneAndMillions
        /// one: 1; many: whole millions
        case oneAndMillions
        /// one: 1, 11; two: 2, 12; few: 3–10, 13–19
        case scottishGaelic
        /// one: ends in 01; two: ends in 02; few: ends in 03, 04
        case slovenian
        /// one: 1; few: 2–4
        case czech
        /// one: 1; few: ends in 2–4 (not 12–14); many: the rest
        case polish
        /// one: ends in 1 (not 11); few: ends in 2–4 (not 12–14); many: the rest
        case eastSlavic
        /// one: ends in 1 (not 11–19); few: ends in 2–9 (not 11–19)
        case lithuanian
        case breton
        case maltese
        case irish
        case manx
        case cornish
        case arabic
        case welsh

        func category(_ n: UInt64) -> PluralCategory {
            let mod10 = n % 10
            let mod100 = n % 100
            let wholeMillions = n != 0 && n % 1_000_000 == 0
            switch self {
            case .none:
                return .other
            case .oneIsOne:
                return n == 1 ? .one : .other
            case .oneIsZeroOrOne:
                return n <= 1 ? .one : .other
            case .tachelhitCentral:
                return n <= 1 || (11...99).contains(n) ? .one : .other
            case .oneEndsInOne:
                return mod10 == 1 && mod100 != 11 ? .one : .other
            case .filipino:
                return mod10 == 4 || mod10 == 6 || mod10 == 9 ? .other : .one
            case .latvian:
                if mod10 == 0 || (11...19).contains(mod100) { return .zero }
                return mod10 == 1 ? .one : .other
            case .zeroAndOne:
                return n == 0 ? .zero : n == 1 ? .one : .other
            case .oneAndTwo:
                return n == 1 ? .one : n == 2 ? .two : .other
            case .tachelhit:
                return n <= 1 ? .one : n <= 10 ? .few : .other
            case .romanian:
                if n == 1 { return .one }
                return n == 0 || (1...19).contains(mod100) ? .few : .other
            case .serboCroatian:
                if mod10 == 1 && mod100 != 11 { return .one }
                return (2...4).contains(mod10) && !(12...14).contains(mod100) ? .few : .other
            case .zeroOneAndMillions:
                return n <= 1 ? .one : wholeMillions ? .many : .other
            case .oneAndMillions:
                return n == 1 ? .one : wholeMillions ? .many : .other
            case .scottishGaelic:
                if n == 1 || n == 11 { return .one }
                if n == 2 || n == 12 { return .two }
                return (3...19).contains(n) ? .few : .other
            case .slovenian:
                if mod100 == 1 { return .one }
                if mod100 == 2 { return .two }
                return mod100 == 3 || mod100 == 4 ? .few : .other
            case .czech:
                return n == 1 ? .one : (2...4).contains(n) ? .few : .other
            case .polish:
                if n == 1 { return .one }
                return (2...4).contains(mod10) && !(12...14).contains(mod100) ? .few : .many
            case .eastSlavic:
                if mod10 == 1 && mod100 != 11 { return .one }
                return (2...4).contains(mod10) && !(12...14).contains(mod100) ? .few : .many
            case .lithuanian:
                if (11...19).contains(mod100) { return .other }
                return mod10 == 1 ? .one : (2...9).contains(mod10) ? .few : .other
            case .breton:
                if mod10 == 1 && ![11, 71, 91].contains(mod100) { return .one }
                if mod10 == 2 && ![12, 72, 92].contains(mod100) { return .two }
                let teens = (10...19).contains(mod100) || (70...79).contains(mod100) || mod100 >= 90
                if [3, 4, 9].contains(mod10) && !teens { return .few }
                return wholeMillions ? .many : .other
            case .maltese:
                if n == 1 { return .one }
                if n == 2 { return .two }
                if n == 0 || (3...10).contains(mod100) { return .few }
                return (11...19).contains(mod100) ? .many : .other
            case .irish:
                if n == 1 { return .one }
                if n == 2 { return .two }
                if (3...6).contains(n) { return .few }
                return (7...10).contains(n) ? .many : .other
            case .manx:
                if mod10 == 1 { return .one }
                if mod10 == 2 { return .two }
                return mod100 % 20 == 0 ? .few : .other
            case .cornish:
                if n == 0 { return .zero }
                if n == 1 { return .one }
                let thousands = n % 100_000
                if [2, 22, 42, 62, 82].contains(mod100)
                    || (n % 1000 == 0
                        && ((1000...20_000).contains(thousands) || [40_000, 60_000, 80_000].contains(thousands)))
                    || n % 1_000_000 == 100_000 {
                    return .two
                }
                if [3, 23, 43, 63, 83].contains(mod100) { return .few }
                return [1, 21, 41, 61, 81].contains(mod100) ? .many : .other
            case .arabic:
                if n <= 2 { return n == 0 ? .zero : n == 1 ? .one : .two }
                if (3...10).contains(mod100) { return .few }
                return mod100 >= 11 ? .many : .other
            case .welsh:
                switch n {
                case 0: return .zero
                case 1: return .one
                case 2: return .two
                case 3: return .few
                case 6: return .many
                default: return .other
                }
            }
        }
    }

    /// Language code to rule family, as grouped in CLDR 47. Languages whose
    /// rule is "one: 1" for whole numbers need no entry, but are listed so the
    /// table states what was checked.
    private static let families: [String: Family] = {
        let groups: [(Family, String)] = [
            (.none, "bm bo dz hnj id ig ii in ja jbo jv jw kde kea km ko lkt lo ms my nqo osa sah ses sg su th to tpi und vi wo yo yue zh"),
            (.oneIsOne, """
                af an asa ast az bal bem bez bg brx ce cgg chr ckb da de dv ee el en eo et eu fi fo fur fy gl gsw ha haw \
                hu ia io jgo ji jmc ka kaj kcg kk kkj kl ks ksb ku ky lb lg lij mas mgo ml mn mr nah nb nd ne nl nn nnh no \
                nr ny nyn om or os pap ps rm rof rwk saq sc sd sdh seh sn so sq ss ssy st sv sw syr ta te teo tig tk tn tr \
                ts ug ur uz ve vo vun wae xh xog yi
                """),
            (.oneIsZeroOrOne, "ak am as bho bn csw doi fa ff gu guw hi hy kab kn ln mg nso pa pcm si ti wa zu"),
            (.tachelhitCentral, "tzm"),
            (.oneEndsInOne, "is mk"),
            (.filipino, "ceb fil tl"),
            (.latvian, "lv prg"),
            (.zeroAndOne, "blo ksh lag"),
            (.oneAndTwo, "he iu iw naq sat se sma smi smj smn sms"),
            (.tachelhit, "shi"),
            (.romanian, "mo ro"),
            (.serboCroatian, "bs hr sh sr"),
            (.zeroOneAndMillions, "fr pt"),
            (.oneAndMillions, "ca es it lld scn vec"),
            (.scottishGaelic, "gd"),
            (.slovenian, "dsb hsb sl"),
            (.czech, "cs sk"),
            (.polish, "pl"),
            (.eastSlavic, "be ru uk"),
            (.lithuanian, "lt"),
            (.breton, "br"),
            (.maltese, "mt"),
            (.irish, "ga"),
            (.manx, "gv"),
            (.cornish, "kw"),
            (.arabic, "ar ars"),
            (.welsh, "cy"),
        ]
        var table: [String: Family] = [:]
        for (family, languages) in groups {
            for language in languages.split(separator: " ") {
                table[String(language)] = family
            }
        }
        return table
    }()
}
