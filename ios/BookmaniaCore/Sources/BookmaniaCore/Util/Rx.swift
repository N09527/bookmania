import Foundation

/// A small wrapper over NSRegularExpression with the Kotlin `Regex` operations the ported code uses.
/// Offsets are UTF-16 offsets of the subject; for Latin-1 strings (one character per byte) they are byte offsets.
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false) {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        // The patterns are constants of this module; a bad one is a programming error.
        re = try! NSRegularExpression(pattern: pattern, options: options) // swiftlint:disable:this force_try
    }

    struct Match {
        let subject: NSString
        let result: NSTextCheckingResult

        /// Whole match.
        var value: String { subject.substring(with: result.range) }
        var range: NSRange { result.range }

        /// Group text, or "" when the group did not take part (Kotlin `groupValues`).
        func group(_ i: Int) -> String {
            guard i < result.numberOfRanges else { return "" }
            let r = result.range(at: i)
            return r.location == NSNotFound ? "" : subject.substring(with: r)
        }

        func groupRange(_ i: Int) -> NSRange? {
            guard i < result.numberOfRanges else { return nil }
            let r = result.range(at: i)
            return r.location == NSNotFound ? nil : r
        }
    }

    func findAll(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(subject: ns, result: $0) }
    }

    func find(_ s: String) -> Match? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Match(subject: ns, result: r)
    }

    func containsMatch(_ s: String) -> Bool { find(s) != nil }

    /// The whole string must match (Kotlin `matchEntire`).
    func matchEntire(_ s: String) -> Match? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length)),
              r.range.location == 0, r.range.length == ns.length else { return nil }
        return Match(subject: ns, result: r)
    }

    func matches(_ s: String) -> Bool { matchEntire(s) != nil }

    /// Replaces every match with the transform's result (Kotlin `replace(input) { … }`).
    func replace(_ s: String, _ transform: (Match) -> String) -> String {
        let ns = s as NSString
        let results = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !results.isEmpty else { return s }
        var out = ""
        var last = 0
        for r in results {
            out += ns.substring(with: NSRange(location: last, length: r.range.location - last))
            out += transform(Match(subject: ns, result: r))
            last = r.range.location + r.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Replaces every match with a literal string.
    func replace(_ s: String, with literal: String) -> String { replace(s) { _ in literal } }
}
