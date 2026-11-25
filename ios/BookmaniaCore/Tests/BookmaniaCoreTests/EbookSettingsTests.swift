import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct EbookSettingsTests {
    @Test func levelsMergeNearestWins() {
        let global = ["fontSize": "22", "lineHeight": "2.0", "bold": "true"]
        let work = ["fontSize": "24", "writingMode": "vertical"]
        let file = ["fontSize": "26", "indent": "book", "paragraphSpacing": "0.5"]
        let s = EbookSettings.resolve([global, work, file])
        #expect(s.fontSize == 26)
        #expect(s.lineHeight == 2.0)
        #expect(s.bold)
        #expect(s.writingMode == "vertical")
        #expect(s.indent == nil)
        #expect(s.paragraphSpacing == 0.5)
        #expect(s.marginTop == 32)
    }

    @Test func invalidValuesFallBackAndRangesClamp() {
        let s = EbookSettings.parse([
            "font": "../evil", "fontSize": "99", "lineHeight": "abc", "letterSpacing": "0.123",
            "marginLeft": "500", "marginRight": "-4", "columns": "three", "bold": "yes", "pageDirection": "rtl",
        ])
        #expect(s.font == "book")
        #expect(s.fontSize == 48)
        #expect(s.lineHeight == 1.8)
        #expect(s.letterSpacing == 0.12)
        #expect(s.marginLeft == 120)
        #expect(s.marginRight == 0)
        #expect(s.columns == "landscape")
        #expect(!s.bold)
        #expect(s.pageDirection == "rtl")
        #expect(EbookSettings.parse(["font": "0123456789abcdef0123456789abcdef"]).font == "0123456789abcdef0123456789abcdef")
    }

    @Test func mapRoundTripAndDirection() {
        var s = EbookSettings()
        s.indent = 2
        s.lineHeight = 1.75
        let map = s.toMap()
        #expect(map["lineHeight"] == "1.75")
        #expect(map["indent"] == "2")
        #expect(map["paragraphSpacing"] == "book")
        #expect(EbookSettings.parse(map) == s)
        #expect(s.rightToLeft(vertical: true))
        #expect(!s.rightToLeft(vertical: false))
        s.pageDirection = "ltr"
        #expect(!s.rightToLeft(vertical: true))
        #expect(EbookSettings.format(1.8) == "1.8")
        #expect(EbookSettings.format(0) == "0")
    }
}
