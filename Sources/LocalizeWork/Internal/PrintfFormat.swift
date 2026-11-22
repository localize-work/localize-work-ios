import Foundation

/// The argument a `printf` conversion reads, as far as passing it safely goes.
enum PrintfArgument: Equatable {
    /// `%@`
    case object
    /// `%d`, `%hd`: a 32-bit integer.
    case int32
    /// `%ld`, `%zd`: an integer as wide as a pointer.
    case int
    /// `%lld`: a 64-bit integer.
    case int64
    /// `%f`, `%g`, `%e`
    case double
    /// `%#@name@`: a plural rule in a strings dictionary. It reads a number;
    /// string catalogs declare it as `lld`.
    case pluralRule
}

/// Reads the conversions of a `printf` format string, to know what each
/// argument position expects before anything is handed to the formatter.
///
/// Passing the formatter an argument of the wrong kind can crash, so this
/// accepts only a subset it is sure about and returns nil for anything else.
enum PrintfFormat {
    /// The kind of argument at each 1-based position, or nil when the format
    /// has a conversion this SDK does not pass arguments to (`%s`, `%c`,
    /// `%p`, `%*d`), mixes numbered and unnumbered conversions, or reads one
    /// position as two kinds.
    static func arguments(of format: String) -> [Int: PrintfArgument]? {
        let scalars = Array(format.unicodeScalars)
        var kinds: [Int: PrintfArgument] = [:]
        var unnumbered = 0
        var numbered = false
        var index = 0

        func digit(_ scalar: Unicode.Scalar) -> Int? {
            scalar.value >= 48 && scalar.value <= 57 ? Int(scalar.value) - 48 : nil
        }

        while index < scalars.count {
            guard scalars[index] == "%" else {
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { return nil }
            if scalars[index] == "%" {
                index += 1
                continue
            }

            // "%2$…": an explicit position.
            var position: Int?
            var lookahead = index
            var number = 0
            while lookahead < scalars.count, let value = digit(scalars[lookahead]), number <= maxPosition {
                number = number * 10 + value
                lookahead += 1
            }
            if lookahead > index, lookahead < scalars.count, scalars[lookahead] == "$" {
                guard (1...maxPosition).contains(number) else { return nil }
                position = number
                index = lookahead + 1
            }

            let kind: PrintfArgument
            if index + 1 < scalars.count, scalars[index] == "#", scalars[index + 1] == "@" {
                // "%#@name@"
                var end = index + 2
                while end < scalars.count, scalars[end] != "@" { end += 1 }
                guard end < scalars.count, end > index + 2 else { return nil }
                kind = .pluralRule
                index = end + 1
            } else {
                let start = index
                while index < scalars.count, "-+ 0#".unicodeScalars.contains(scalars[index]) { index += 1 }
                while index < scalars.count, digit(scalars[index]) != nil { index += 1 }
                if index < scalars.count, scalars[index] == "." {
                    index += 1
                    while index < scalars.count, digit(scalars[index]) != nil { index += 1 }
                }
                let plain = index == start
                var length = ""
                while index < scalars.count, "hlqztj".unicodeScalars.contains(scalars[index]), length.count < 2 {
                    length.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count else { return nil }
                switch scalars[index] {
                case "@":
                    guard plain, length.isEmpty else { return nil }
                    kind = .object
                case "d", "i", "u", "o", "x", "X":
                    switch length {
                    case "", "h", "hh": kind = .int32
                    case "l", "z", "t": kind = .int
                    case "ll", "q", "j": kind = .int64
                    default: return nil
                    }
                case "a", "A", "e", "E", "f", "F", "g", "G":
                    guard length.isEmpty || length == "l" else { return nil }
                    kind = .double
                default:
                    return nil
                }
                index += 1
            }

            if let position {
                numbered = true
                guard kinds[position] == nil || kinds[position] == kind else { return nil }
                kinds[position] = kind
            } else {
                unnumbered += 1
                guard unnumbered <= maxPosition else { return nil }
                kinds[unnumbered] = kind
            }
            if numbered && unnumbered > 0 { return nil }
        }
        return kinds
    }

    /// More positions than any real string has; a bound for the scan.
    static let maxPosition = 32
}
