import Foundation

/// The values for a string's placeholders, in the order they were written.
///
/// Write it as a dictionary literal: `["name": "Ann", "city": "Tartu"]`.
/// Published strings find a value by its name, so there the order does not
/// matter. A bundled string that uses `%1$@`-style placeholders has only
/// positions, and takes the values in this order.
public struct LocalizeArguments: ExpressibleByDictionaryLiteral {
    let pairs: [(name: String, value: Any)]

    public init(dictionaryLiteral elements: (String, Any)...) {
        pairs = elements.map { (name: $0.0, value: $0.1) }
    }

    /// For a list built at run time.
    public init(_ pairs: [(String, Any)]) {
        self.pairs = pairs.map { (name: $0.0, value: $0.1) }
    }

    func value(named name: String) -> Any? {
        pairs.first { $0.name == name }?.value
    }

    /// A value as it is shown in a string.
    static func text(_ value: Any) -> String {
        if let text = value as? String { return text }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { text($0.value) } ?? ""
        }
        return String(describing: value)
    }
}
