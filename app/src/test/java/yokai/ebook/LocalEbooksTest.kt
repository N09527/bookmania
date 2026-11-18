package yokai.ebook

import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.util.Locale
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class LocalEbooksTest {

    @Test
    fun `only MOBI and AZW3 are text-only extensions`() {
        assertTrue(LocalEbooks.isTextOnly("mobi"))
        assertTrue(LocalEbooks.isTextOnly("AZW3"))
        assertFalse(LocalEbooks.isTextOnly("epub"))
        assertFalse(LocalEbooks.isTextOnly("cbz"))
        assertFalse(LocalEbooks.isTextOnly("azw"))
        assertFalse(LocalEbooks.isTextOnly(null))
    }

    @Test
    fun `ISO 8601 dates from EPUB and MOBI metadata`() {
        val instant = OffsetDateTime.parse("2026-11-18T06:21:55+00:00").toInstant().toEpochMilli()
        // Calibre writes EXTH 106 with microseconds.
        assertEquals(instant, LocalEbooks.parseDate("2026-11-18T06:21:55.145693+00:00"))
        assertEquals(instant, LocalEbooks.parseDate("2026-11-18T06:21:55Z"))
        assertEquals(instant, LocalEbooks.parseDate(" 2026-11-18T14:21:55+08:00 "))
        val localMidnight = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).parse("2026-11-18")!!.time
        assertEquals(localMidnight, LocalEbooks.parseDate("2026-11-18"))
        assertNull(LocalEbooks.parseDate("Spring 2026"))
        assertNull(LocalEbooks.parseDate(""))
    }
}
