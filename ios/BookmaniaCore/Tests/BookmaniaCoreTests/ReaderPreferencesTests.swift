import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct ReaderPreferencesTests {
    @Test func defaultsAndAndroidKeys() {
        let store = MemoryPreferenceStore()
        let prefs = ReaderPreferences(store)
        #expect(prefs.textPageTurn == "curl")
        #expect(prefs.textGutterShadow)
        #expect(!prefs.pagerCurl)
        #expect(prefs.pagerGutterShadow)
        #expect(prefs.readerTheme == 2)
        #expect(prefs.navigationModePager == 0)
        #expect(prefs.pagerNavInverted == .none)
        #expect(!prefs.incognitoMode)
        prefs.textPageTurn = "slide"
        prefs.textGutterShadow = false
        prefs.pagerNavInverted = .both
        prefs.readerTheme = 4
        #expect(store.values["pref_ebook_page_turn"] == "slide")
        #expect(store.values["pref_ebook_gutter_shadow"] == "false")
        #expect(store.values["reader_tapping_inverted"] == "BOTH")
        #expect(store.values["pref_reader_theme_key"] == "4")
        store.set("pref_ebook_page_turn", "sideways")
        #expect(prefs.textPageTurn == "curl")
        #expect(ReaderPreferences.types["pref_ebook_gutter_shadow"] == .bool)
    }

    @Test func themes() {
        #expect(ReaderTheme.resolve(setting: 0, systemDark: true).backgroundHex == "#FFFFFF")
        #expect(ReaderTheme.resolve(setting: 1, systemDark: false) == ReaderTheme(backgroundHex: "#000000", textHex: "#E0E0E0", dark: true))
        #expect(ReaderTheme.resolve(setting: 4, systemDark: false).backgroundHex == "#202125")
        #expect(ReaderTheme.resolve(setting: 2, systemDark: false).dark == false)
        #expect(ReaderTheme.resolve(setting: 2, systemDark: true).backgroundHex == "#202125")
        let (r, g, b) = ReaderTheme.components("#202125")
        #expect(abs(r - 32.0 / 255) < 1e-9 && abs(g - 33.0 / 255) < 1e-9 && abs(b - 37.0 / 255) < 1e-9)
    }

    @Test func tapZonesFollowAndroid() {
        let standard = TapNavigation(mode: 0)
        #expect(standard.action(x: 0.1, y: 0.5) == .left)
        #expect(standard.action(x: 0.5, y: 0.5) == .menu)
        #expect(standard.action(x: 0.9, y: 0.5) == .right)
        #expect(standard.turn(x: 0.1, y: 0.5, rtl: true) == true) // the next page is on the left
        #expect(standard.turn(x: 0.1, y: 0.5, rtl: false) == false)
        #expect(standard.turn(x: 0.5, y: 0.2, rtl: false) == nil)
        let l = TapNavigation(mode: 1)
        #expect(l.action(x: 0.5, y: 0.1) == .previous)
        #expect(l.action(x: 0.1, y: 0.5) == .previous)
        #expect(l.action(x: 0.5, y: 0.5) == .menu)
        #expect(l.action(x: 0.9, y: 0.5) == .next)
        #expect(l.action(x: 0.5, y: 0.9) == .next)
        // Inverted both ways, the L turns around.
        let lInverted = TapNavigation(mode: 1, invert: .both)
        #expect(lInverted.action(x: 0.5, y: 0.1) == .next)
        #expect(lInverted.action(x: 0.5, y: 0.9) == .previous)
        let kindle = TapNavigation(mode: 2)
        #expect(kindle.action(x: 0.5, y: 0.1) == .menu)
        #expect(kindle.action(x: 0.2, y: 0.5) == .previous)
        #expect(kindle.action(x: 0.7, y: 0.5) == .next)
        let edge = TapNavigation(mode: 3)
        #expect(edge.action(x: 0.5, y: 0.9) == .previous)
        #expect(edge.action(x: 0.5, y: 0.5) == .menu)
        #expect(edge.action(x: 0.9, y: 0.1) == .next)
        #expect(TapNavigation(mode: 5).action(x: 0.1, y: 0.5) == .menu)
        // Horizontal inversion swaps the sides of "right and left".
        #expect(TapNavigation(mode: 4, invert: .horizontal).action(x: 0.1, y: 0.5) == .right)
    }

    @Test func shellSettingsFromTypesetting() throws {
        var s = EbookSettings()
        s.font = "0123456789abcdef0123456789abcdef"
        s.bold = true
        s.indent = 2
        s.marginLeft = 40
        let theme = ReaderTheme.resolve(setting: 1, systemDark: false)
        let url = ReaderURLs.fontURL("0123456789abcdef0123456789abcdef")
        let shell = ShellSettings(settings: s, vertical: true, rtl: true, theme: theme, importedFontURL: url)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(shell.json().utf8)) as? [String: Any])
        #expect((object["font"] as? [String: String]) == ["kind": "imported", "url": url])
        #expect(object["bold"] as? Bool == true)
        #expect(object["indent"] as? Double == 2)
        #expect((object["margins"] as? [String: Any])?["left"] as? Int == 40)
        #expect(object["background"] as? String == "#000000")
        #expect(object["dark"] as? Bool == true)
        // A deleted imported font falls back to the book's font.
        let missing = ShellSettings(settings: s, vertical: true, rtl: true, theme: theme, importedFontURL: nil)
        #expect(missing.font == nil)
        s.font = "sans"
        #expect(ShellSettings(settings: s, vertical: false, rtl: false, theme: theme, importedFontURL: nil).font == ["kind": "sans"])
        #expect(EbookSettings().vertical(bookVertical: true))
        var horizontal = EbookSettings()
        horizontal.writingMode = EbookSettings.modeHorizontal
        #expect(!horizontal.vertical(bookVertical: true))
    }
}
