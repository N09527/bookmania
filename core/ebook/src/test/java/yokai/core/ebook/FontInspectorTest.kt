package yokai.core.ebook

import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import yokai.core.ebook.font.FontFormat
import yokai.core.ebook.font.FontInspector
import yokai.core.ebook.font.InvalidFontException

class FontInspectorTest {

    private fun font(name: String) = Fixtures.bytes("fonts/$name")

    @Test
    fun `TrueType font with vertical metrics and vert`() {
        val info = FontInspector.inspect(font("vertical-ok.ttf"))
        info.format shouldBe FontFormat.TRUETYPE
        info.hasVerticalMetrics shouldBe true
        info.hasVerticalGlyphs shouldBe true
        info.supportsVertical shouldBe true
        // The Traditional Chinese name is preferred over the English one.
        info.familyName shouldBe "書狂測試直排"
    }

    @Test
    fun `font without vertical data is reported`() {
        val info = FontInspector.inspect(font("horizontal-only.ttf"))
        info.hasVerticalMetrics shouldBe false
        info.hasVerticalGlyphs shouldBe false
        info.supportsVertical shouldBe false
        info.familyName shouldBe "Bookmania Test Horizontal"
    }

    @Test
    fun `CFF OpenType font with vrt2`() {
        val info = FontInspector.inspect(font("vertical-cff.otf"))
        info.format shouldBe FontFormat.OPENTYPE_CFF
        info.supportsVertical shouldBe true
        info.familyName shouldBe "Bookmania Test CFF"
    }

    @Test
    fun `collections, WOFF and other files are refused`() {
        val ttc = "ttcf".toByteArray() + ByteArray(12)
        assertThrows<InvalidFontException> { FontInspector.inspect(ttc) }
        assertThrows<InvalidFontException> { FontInspector.inspect("wOF2".toByteArray() + ByteArray(40)) }
        assertThrows<InvalidFontException> { FontInspector.inspect(Fixtures.bytes("zh-vertical.epub")) }
        assertThrows<InvalidFontException> { FontInspector.inspect(ByteArray(5)) }
        // A real font cut short: the table directory points outside the file.
        assertThrows<InvalidFontException> { FontInspector.inspect(font("vertical-ok.ttf").copyOf(200)) }
    }
}
