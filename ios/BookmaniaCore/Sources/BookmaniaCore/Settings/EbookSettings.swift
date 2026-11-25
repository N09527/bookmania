import Foundation

/// Typesetting settings of the text reader (port of Android's yokai.ebook.settings.EbookSettings, design section 5.6).
/// Lengths are CSS px, which equal points in the reader's web view.
///
/// Settings come in three levels, nearest wins: global → work (local source folder) → file. Each level is a map of
/// `Key` to string values; a level only holds the keys it overrides. `book` means "use the book's own styles" where
/// the table allows it. The string values are the same as on Android, so they can travel in backups.
public struct EbookSettings: Equatable, Sendable {
    /// `book`, `sans`, `serif` or the id of an imported font.
    public var font: String = EbookSettings.fontBook
    public var fontSize: Int = 20
    public var lineHeight: Double = 1.8
    public var letterSpacing: Double = 0
    /// First-line indent in em; nil = the book's.
    public var indent: Double? = nil
    /// Space after paragraphs in em; nil = the book's.
    public var paragraphSpacing: Double? = nil
    public var marginTop: Int = 32
    public var marginBottom: Int = 32
    public var marginLeft: Int = 20
    public var marginRight: Int = 20
    /// `book`, `vertical` or `horizontal`.
    public var writingMode: String = EbookSettings.book
    /// `auto` (vertical: right-to-left, horizontal: left-to-right), `rtl` or `ltr`.
    public var pageDirection: String = EbookSettings.directionAuto
    /// Two columns: `off`, `on` or `landscape` (only when the screen is wider than tall).
    public var columns: String = EbookSettings.columnsLandscape
    /// Body text in bold; false keeps the book's own weights.
    public var bold: Bool = false

    public init() {}

    public enum Key: String, CaseIterable, Sendable {
        case font, fontSize, lineHeight, letterSpacing, indent, paragraphSpacing
        case marginTop, marginBottom, marginLeft, marginRight
        case writingMode, pageDirection, columns, bold
    }

    public static let book = "book"
    public static let fontBook = book
    public static let fontSans = "sans"
    public static let fontSerif = "serif"
    public static let modeVertical = "vertical"
    public static let modeHorizontal = "horizontal"
    public static let directionAuto = "auto"
    public static let directionRTL = "rtl"
    public static let directionLTR = "ltr"
    public static let columnsOff = "off"
    public static let columnsOn = "on"
    public static let columnsLandscape = "landscape"

    public static let defaults = EbookSettings()

    /// Ranges and steps of the settings table. The steps are the sliders'; a typed value can be finer: lengths in
    /// em to 0.01, margins to 1 pt.
    public enum Range {
        public static let fontSize = 12 ... 48
        public static let lineHeight = 1.0 ... 3.0
        public static let lineHeightStep = 0.1
        public static let letterSpacing = 0.0 ... 0.5
        public static let letterSpacingStep = 0.05
        public static let indent = 0.0 ... 4.0
        public static let indentStep = 0.5
        public static let paragraphSpacing = 0.0 ... 3.0
        public static let paragraphSpacingStep = 0.1
        public static let margin = 0 ... 120
        public static let marginStep = 2
    }

    /// Whether pages turn right-to-left (next page on the left), given the resolved writing mode.
    public func rightToLeft(vertical: Bool) -> Bool {
        switch pageDirection {
        case EbookSettings.directionRTL: return true
        case EbookSettings.directionLTR: return false
        default: return vertical
        }
    }

    public func toMap() -> [String: String] {
        [
            Key.font.rawValue: font,
            Key.fontSize.rawValue: String(fontSize),
            Key.lineHeight.rawValue: EbookSettings.format(lineHeight),
            Key.letterSpacing.rawValue: EbookSettings.format(letterSpacing),
            Key.indent.rawValue: indent.map(EbookSettings.format) ?? EbookSettings.book,
            Key.paragraphSpacing.rawValue: paragraphSpacing.map(EbookSettings.format) ?? EbookSettings.book,
            Key.marginTop.rawValue: String(marginTop),
            Key.marginBottom.rawValue: String(marginBottom),
            Key.marginLeft.rawValue: String(marginLeft),
            Key.marginRight.rawValue: String(marginRight),
            Key.writingMode.rawValue: writingMode,
            Key.pageDirection.rawValue: pageDirection,
            Key.columns.rawValue: columns,
            Key.bold.rawValue: bold ? "true" : "false",
        ]
    }

    /// Merges the levels (later wins) and parses the result; invalid values fall back to the defaults.
    public static func resolve(_ levels: [[String: String]]) -> EbookSettings {
        var merged = [String: String]()
        for level in levels { merged.merge(level) { _, new in new } }
        return parse(merged)
    }

    public static func parse(_ values: [String: String]) -> EbookSettings {
        let d = defaults
        func str(_ k: Key) -> String? { values[k.rawValue]?.trimmingCharacters(in: .whitespaces) }
        var s = EbookSettings()
        if let f = str(.font), !f.isEmpty, fontId.matches(f) { s.font = f } else { s.font = d.font }
        s.fontSize = str(.fontSize).flatMap { Int($0) }.map { min(max($0, Range.fontSize.lowerBound), Range.fontSize.upperBound) } ?? d.fontSize
        s.lineHeight = decimal(str(.lineHeight), Range.lineHeight) ?? d.lineHeight
        s.letterSpacing = decimal(str(.letterSpacing), Range.letterSpacing) ?? d.letterSpacing
        s.indent = optional(str(.indent), Range.indent, d.indent)
        s.paragraphSpacing = optional(str(.paragraphSpacing), Range.paragraphSpacing, d.paragraphSpacing)
        s.marginTop = margin(str(.marginTop)) ?? d.marginTop
        s.marginBottom = margin(str(.marginBottom)) ?? d.marginBottom
        s.marginLeft = margin(str(.marginLeft)) ?? d.marginLeft
        s.marginRight = margin(str(.marginRight)) ?? d.marginRight
        if let m = str(.writingMode), [book, modeVertical, modeHorizontal].contains(m) { s.writingMode = m } else { s.writingMode = d.writingMode }
        if let p = str(.pageDirection), [directionAuto, directionRTL, directionLTR].contains(p) { s.pageDirection = p } else { s.pageDirection = d.pageDirection }
        if let c = str(.columns), [columnsOff, columnsOn, columnsLandscape].contains(c) { s.columns = c } else { s.columns = d.columns }
        switch str(.bold) {
        case "true": s.bold = true
        case "false": s.bold = false
        default: s.bold = d.bold
        }
        return s
    }

    /// Imported fonts are referenced by a 32-character hexadecimal id.
    private static let fontId = Rx("book|sans|serif|[0-9a-f]{32}")

    /// A number within `range`, to 0.01 (a typed value can be finer than the slider's step).
    static func decimal(_ text: String?, _ range: ClosedRange<Double>) -> Double? {
        guard let text, let v = Double(text), v.isFinite else { return nil }
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        let rounded = (clamped * 100).rounded() / 100
        return min(max(rounded, range.lowerBound), range.upperBound)
    }

    static func optional(_ text: String?, _ range: ClosedRange<Double>, _ fallback: Double?) -> Double? {
        guard let text else { return fallback }
        if text == book { return nil }
        return decimal(text, range) ?? fallback
    }

    /// Whole points within the range.
    static func margin(_ text: String?) -> Int? {
        guard let text, let v = Int(text) else { return nil }
        return min(max(v, Range.margin.lowerBound), Range.margin.upperBound)
    }

    /// 1.8 rather than 1.8000000000000000444 (two decimals, trailing zeros removed).
    public static func format(_ value: Double) -> String {
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
