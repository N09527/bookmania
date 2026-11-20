package yokai.ebook

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import yokai.ebook.settings.EbookSettings

class EbookSettingsTest {

    @Test
    fun `defaults follow the settings table`() {
        val d = EbookSettings.resolve()
        assertEquals(EbookSettings.FONT_BOOK, d.font)
        assertEquals(20, d.fontSize)
        assertEquals(1.8f, d.lineHeight)
        assertEquals(0f, d.letterSpacing)
        assertNull(d.indent)
        assertNull(d.paragraphSpacing)
        assertEquals(listOf(32, 32, 20, 20), listOf(d.marginTop, d.marginBottom, d.marginLeft, d.marginRight))
        assertEquals(EbookSettings.BOOK, d.writingMode)
        assertEquals(EbookSettings.DIRECTION_AUTO, d.pageDirection)
        assertEquals(EbookSettings.COLUMNS_LANDSCAPE, d.columns)
    }

    @Test
    fun `nearest level wins, missing keys are inherited`() {
        val global = mapOf("fontSize" to "22", "lineHeight" to "2", "indent" to "1")
        val work = mapOf("fontSize" to "26", "indent" to "book")
        val file = mapOf("lineHeight" to "1.5")
        val s = EbookSettings.resolve(global, work, file)
        assertEquals(26, s.fontSize) // work overrides global
        assertEquals(1.5f, s.lineHeight) // file overrides global
        assertNull(s.indent) // work sets "book's indent" explicitly
        assertEquals(EbookSettings.resolve(global).copy(fontSize = 26, lineHeight = 1.5f, indent = null), s)
    }

    @Test
    fun `values are clamped to the table and snapped to its steps`() {
        val s = EbookSettings.parse(
            mapOf(
                "fontSize" to "99", "lineHeight" to "0.3", "letterSpacing" to "0.123", "indent" to "1.3",
                "paragraphSpacing" to "7", "marginTop" to "-5", "marginLeft" to "37", "marginRight" to "500",
            ),
        )
        assertEquals(48, s.fontSize)
        assertEquals(1.0f, s.lineHeight)
        assertEquals(0.1f, s.letterSpacing)
        assertEquals(1.5f, s.indent)
        assertEquals(3.0f, s.paragraphSpacing)
        assertEquals(0, s.marginTop)
        assertEquals(36, s.marginLeft)
        assertEquals(120, s.marginRight)
    }

    @Test
    fun `invalid values fall back to the defaults`() {
        val s = EbookSettings.parse(
            mapOf(
                "font" to "../../etc/passwd", "fontSize" to "big", "lineHeight" to "NaN", "writingMode" to "diagonal",
                "pageDirection" to "up", "indent" to "x", "columns" to "3",
            ),
        )
        assertEquals(EbookSettings.DEFAULTS, s)
    }

    @Test
    fun `imported font ids are accepted`() {
        val id = "0123456789abcdef0123456789abcdef"
        assertEquals(id, EbookSettings.parse(mapOf("font" to id)).font)
        assertEquals(EbookSettings.FONT_SERIF, EbookSettings.parse(mapOf("font" to "serif")).font)
    }

    @Test
    fun `page direction follows the writing mode unless set`() {
        assertTrue(EbookSettings().rightToLeft(vertical = true))
        assertFalse(EbookSettings().rightToLeft(vertical = false))
        assertTrue(EbookSettings(pageDirection = EbookSettings.DIRECTION_RTL).rightToLeft(vertical = false))
        assertFalse(EbookSettings(pageDirection = EbookSettings.DIRECTION_LTR).rightToLeft(vertical = true))
    }

    @Test
    fun `map round trip`() {
        val s = EbookSettings(
            font = "serif", fontSize = 24, lineHeight = 2.2f, letterSpacing = 0.05f, indent = 2f, paragraphSpacing = 0.5f,
            columns = EbookSettings.COLUMNS_ON,
        )
        assertEquals(s, EbookSettings.parse(s.toMap()))
        assertEquals("2.2", s.toMap()["lineHeight"])
        assertEquals("book", EbookSettings().toMap()["indent"])
    }
}
