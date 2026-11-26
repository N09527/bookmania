import Foundation

/// Reader settings that are not part of the three typesetting levels, stored under Android's preference keys so that
/// they mean the same in backups (PreferenceKeys.kt, PageTurnPreferences.kt, GutterPreferences.kt). Booleans and
/// numbers are kept as text ("true", "2"); `PreferenceType` tells the backup which type Android uses for each key.
public final class ReaderPreferences: @unchecked Sendable {
    private let store: PreferenceStore

    public init(_ store: PreferenceStore) { self.store = store }

    public enum Keys {
        public static let textPageTurn = "pref_ebook_page_turn"
        public static let textGutterShadow = "pref_ebook_gutter_shadow"
        public static let pagerCurl = "pref_bookmania_pager_curl"
        public static let pagerGutterShadow = "pref_bookmania_pager_gutter_shadow"
        public static let readerTheme = "pref_reader_theme_key"
        public static let navigationModePager = "reader_navigation_mode_pager"
        public static let pagerNavInverted = "reader_tapping_inverted"
        public static let keepScreenOn = "pref_keep_screen_on_key"
        public static let defaultReadingMode = "pref_default_reading_mode_key"
        public static let pageLayout = "page_layout"
        public static let invertDoublePages = "invert_double_pages"
        public static let incognitoMode = "incognito_mode"
    }

    /// The type Android stores a key with (for backups).
    public enum PreferenceType: Sendable { case bool, int, string }

    public static let types: [String: PreferenceType] = [
        Keys.textPageTurn: .string,
        Keys.textGutterShadow: .bool,
        Keys.pagerCurl: .bool,
        Keys.pagerGutterShadow: .bool,
        Keys.readerTheme: .int,
        Keys.navigationModePager: .int,
        Keys.pagerNavInverted: .string,
        Keys.keepScreenOn: .bool,
        Keys.defaultReadingMode: .int,
        Keys.pageLayout: .int,
        Keys.invertDoublePages: .bool,
        Keys.incognitoMode: .bool,
    ]

    // MARK: Page turn animation (PageTurnPreferences)

    public static let pageTurnNone = "none"
    public static let pageTurnSlide = "slide"
    public static let pageTurnCurl = "curl"

    /// The text reader's page turn: none, slide or curl, for all books; curl unless chosen otherwise.
    public var textPageTurn: String {
        get {
            let v = store.string(Keys.textPageTurn)
            return [ReaderPreferences.pageTurnNone, ReaderPreferences.pageTurnSlide, ReaderPreferences.pageTurnCurl]
                .contains(v ?? "") ? v! : ReaderPreferences.pageTurnCurl
        }
        set { store.set(Keys.textPageTurn, newValue) }
    }

    /// The image reader's paged modes turn the page with a curl (off by default).
    public var pagerCurl: Bool {
        get { bool(Keys.pagerCurl, false) }
        set { setBool(Keys.pagerCurl, newValue) }
    }

    // MARK: Gutter shadow (GutterPreferences): on unless turned off

    public var textGutterShadow: Bool {
        get { bool(Keys.textGutterShadow, true) }
        set { setBool(Keys.textGutterShadow, newValue) }
    }

    public var pagerGutterShadow: Bool {
        get { bool(Keys.pagerGutterShadow, true) }
        set { setBool(Keys.pagerGutterShadow, newValue) }
    }

    // MARK: Reader

    /// Background of the readers (ReaderBackgroundColor): white 0, black 1, by theme 2 (default) or 3, gray 4.
    public var readerTheme: Int {
        get { int(Keys.readerTheme, 2) }
        set { store.set(Keys.readerTheme, String(newValue)) }
    }

    /// Tap zones of the paged readers: 0 default (left / right thirds), 1 L-shaped, 2 Kindle-ish, 3 edge,
    /// 4 right and left, 5 none.
    public var navigationModePager: Int {
        get { int(Keys.navigationModePager, 0) }
        set { store.set(Keys.navigationModePager, String(newValue)) }
    }

    /// Inverted tap zones: NONE, HORIZONTAL, VERTICAL or BOTH (an enum name, as on Android).
    public var pagerNavInverted: TapNavigation.Invert {
        get { TapNavigation.Invert(rawValue: store.string(Keys.pagerNavInverted) ?? "") ?? .none }
        set { store.set(Keys.pagerNavInverted, newValue.rawValue) }
    }

    public var keepScreenOn: Bool {
        get { bool(Keys.keepScreenOn, true) }
        set { setBool(Keys.keepScreenOn, newValue) }
    }

    /// Nothing about reading is recorded (positions, read state, history), as in Android's incognito mode.
    public var incognitoMode: Bool {
        get { bool(Keys.incognitoMode, false) }
        set { setBool(Keys.incognitoMode, newValue) }
    }

    /// The tap zones for the current settings.
    public var navigation: TapNavigation {
        TapNavigation(mode: navigationModePager, invert: pagerNavInverted)
    }

    // MARK: Typed access

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        switch store.string(key) {
        case "true": return true
        case "false": return false
        default: return fallback
        }
    }

    func setBool(_ key: String, _ value: Bool) { store.set(key, value ? "true" : "false") }

    func int(_ key: String, _ fallback: Int) -> Int { store.string(key).flatMap { Int($0) } ?? fallback }
}

/// The reader's colours: the reader background setting, and the system appearance for the "by theme" choices
/// (EbookReaderActivity.resolveColors on Android).
public struct ReaderTheme: Equatable, Sendable {
    public let backgroundHex: String
    public let textHex: String
    /// Dark background (the shell then also overrides the book's text colours).
    public let dark: Bool

    public static func resolve(setting: Int, systemDark: Bool) -> ReaderTheme {
        switch setting {
        case 0: return ReaderTheme(backgroundHex: "#FFFFFF", textHex: "#000000", dark: false)
        case 1: return ReaderTheme(backgroundHex: "#000000", textHex: "#E0E0E0", dark: true)
        case 4: return gray
        default: return systemDark ? gray : ReaderTheme(backgroundHex: "#FFFFFF", textHex: "#000000", dark: false)
        }
    }

    /// The dark reader's gray, rgb(32, 33, 37).
    static let gray = ReaderTheme(backgroundHex: "#202125", textHex: "#E0E0E0", dark: true)

    /// Red, green and blue (0...1) of a `#RRGGBB` colour.
    public static func components(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let v = Int(digits, radix: 16) else { return (0, 0, 0) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// Tap zones of the paged readers (ViewerNavigation and its subclasses on Android). Positions are fractions of the
/// view (0...1); a point in no region opens the menu.
public struct TapNavigation: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case menu, previous, next, left, right }

    public enum Invert: String, CaseIterable, Sendable {
        case none = "NONE", horizontal = "HORIZONTAL", vertical = "VERTICAL", both = "BOTH"
    }

    public struct Region: Equatable, Sendable {
        public var left, top, right, bottom: Double
        public var action: Action

        /// Android's RectF.contains: left and top inclusive, right and bottom exclusive.
        func contains(_ x: Double, _ y: Double) -> Bool {
            left < right && top < bottom && x >= left && x < right && y >= top && y < bottom
        }

        func inverted(_ mode: Invert) -> Region {
            switch mode {
            case .none: return self
            case .horizontal: return Region(left: 1 - right, top: top, right: 1 - left, bottom: bottom, action: action)
            case .vertical: return Region(left: left, top: 1 - bottom, right: right, bottom: 1 - top, action: action)
            case .both: return Region(left: 1 - right, top: 1 - bottom, right: 1 - left, bottom: 1 - top, action: action)
            }
        }
    }

    public let mode: Int
    public let invert: Invert

    public init(mode: Int, invert: Invert = .none) {
        self.mode = mode
        self.invert = invert
    }

    public var regions: [Region] {
        switch mode {
        case 1: // L-shaped
            return [
                Region(left: 0, top: 0.33, right: 0.33, bottom: 0.66, action: .previous),
                Region(left: 0, top: 0, right: 1, bottom: 0.33, action: .previous),
                Region(left: 0.66, top: 0.33, right: 1, bottom: 0.66, action: .next),
                Region(left: 0, top: 0.66, right: 1, bottom: 1, action: .next),
            ]
        case 2: // Kindle-ish
            return [
                Region(left: 0.33, top: 0.33, right: 1, bottom: 1, action: .next),
                Region(left: 0, top: 0.33, right: 0.33, bottom: 1, action: .previous),
            ]
        case 3: // edge
            return [
                Region(left: 0, top: 0, right: 0.33, bottom: 1, action: .next),
                Region(left: 0.33, top: 0.66, right: 0.66, bottom: 1, action: .previous),
                Region(left: 0.66, top: 0, right: 1, bottom: 1, action: .next),
            ]
        case 5: // none
            return []
        default: // 0 and 4: right and left
            return [
                Region(left: 0, top: 0, right: 0.33, bottom: 1, action: .left),
                Region(left: 0.66, top: 0, right: 1, bottom: 1, action: .right),
            ]
        }
    }

    /// What a tap at (x, y) does (fractions of the view).
    public func action(x: Double, y: Double) -> Action {
        regions.map { $0.inverted(invert) }.first { $0.contains(x, y) }?.action ?? .menu
    }

    /// Whether a tap at (x, y) turns forward (true), back (false), or opens the menu (nil), for pages that turn
    /// right to left (`rtl`: the next page is on the left) or left to right.
    public func turn(x: Double, y: Double, rtl: Bool) -> Bool? {
        switch action(x: x, y: y) {
        case .menu: return nil
        case .next: return true
        case .previous: return false
        case .left: return rtl
        case .right: return !rtl
        }
    }
}
