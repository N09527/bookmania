package yokai.ebook

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import yokai.ebook.data.EbookLocator
import yokai.ebook.data.ReadingProgress

class ReadingProgressTest {

    // Three documents: an image-only page (0 characters), 1000 and 3000 characters.
    private val progress = ReadingProgress(intArrayOf(0, 1000, 3000))

    @Test
    fun `whole-book fraction from the document and the fraction in it`() {
        assertEquals(0.0, progress.total(0, 0.5), 1e-9) // nothing before, no text in the document
        assertEquals(0.0, progress.total(1, 0.0), 1e-9)
        assertEquals(0.125, progress.total(1, 0.5), 1e-9) // 500 of 4000
        assertEquals(0.25, progress.total(2, 0.0), 1e-9) // 1000 of 4000
        assertEquals(1.0, progress.total(2, 1.0), 1e-9)
        assertEquals(1.0, progress.total(2, 7.0), 1e-9) // clamped
        assertEquals(0.0, progress.total(9, 0.5), 1e-9) // unknown document
    }

    @Test
    fun `fraction of the book back to a document`() {
        assertEquals(1 to 0.0, progress.locate(0.0)) // the first document with text
        assertEquals(1, progress.locate(0.125).first)
        assertEquals(0.5, progress.locate(0.125).second, 1e-9)
        assertEquals(2, progress.locate(0.5).first)
        assertEquals(1.0 / 3, progress.locate(0.5).second, 1e-9) // 2000 of 4000 = 1000 into the third
        assertEquals(2 to 1.0, progress.locate(1.0))
    }

    @Test
    fun `a book without any text counts its documents as equal parts`() {
        val pictures = ReadingProgress(intArrayOf(0, 0, 0, 0))
        assertEquals(0.0, pictures.total(0, 0.0), 1e-9)
        assertEquals(0.625, pictures.total(2, 0.5), 1e-9)
        assertEquals(1.0, pictures.total(3, 1.0), 1e-9)
        assertEquals(2, pictures.locate(0.625).first)
        assertEquals(0.5, pictures.locate(0.625).second, 1e-9)
        assertEquals(3 to 1.0, pictures.locate(1.0))
        assertEquals(0 to 0.0, ReadingProgress(IntArray(0)).locate(0.7))
        assertNull(pictures.pages(1, page = 0, pages = 3, atEnd = false)) // no page numbers without text
    }

    @Test
    fun `page numbers are the open document's real pages, the others estimated with its page size`() {
        // Document 1 has 1000 characters on 10 pages (100 per page): 0 pages before it, 30 after it.
        assertEquals(0 to 40, progress.pages(1, page = 0, pages = 10, atEnd = false))
        assertEquals(4 to 40, progress.pages(1, page = 4, pages = 10, atEnd = false))
        // Document 2 laid out on 25 pages (120 per page): 1000 characters before it make 8 pages.
        assertEquals(8 to 33, progress.pages(2, page = 0, pages = 25, atEnd = false))
        assertEquals(20 to 33, progress.pages(2, page = 12, pages = 25, atEnd = false))
        assertEquals(32 to 33, progress.pages(2, page = 24, pages = 25, atEnd = true)) // the last page
        assertEquals(32 to 33, progress.pages(2, page = 99, pages = 25, atEnd = false)) // never past the last page
        assertNull(progress.pages(0, page = 0, pages = 1, atEnd = false)) // no text to measure the page size with
        assertNull(progress.pages(1, page = 0, pages = 0, atEnd = false))
    }

    @Test
    fun `locator json round trip and validation`() {
        val locator = EbookLocator(
            spine = 2, href = "OEBPS/text/ch02.xhtml", location = listOf(17, 4), text = "【第１３段】長一點的段落",
            progression = 0.29, total = 0.4, atEnd = false, updatedAt = 1_700_000_000_000,
        )
        assertEquals(locator, EbookLocator.fromJson(locator.toJson()))
        val picturePage = EbookLocator(spine = 0, href = "a.xhtml", pageProgression = 0.5)
        assertEquals(picturePage, EbookLocator.fromJson(picturePage.toJson()))
        // Unknown fields from a newer version are ignored; broken or out-of-range values are rejected.
        assertEquals(
            EbookLocator(spine = 1, href = "b.xhtml"),
            EbookLocator.fromJson("""{"spine":1,"href":"b.xhtml","futureField":3}"""),
        )
        assertNull(EbookLocator.fromJson("""{"spine":1,"href":"b.xhtml","progression":1.5}"""))
        assertNull(EbookLocator.fromJson("""{"spine":-1,"href":"b.xhtml"}"""))
        assertNull(EbookLocator.fromJson("""{"spine":1,"href":"b.xhtml","location":[3]}"""))
        assertNull(EbookLocator.fromJson("not json"))
        assertNull(EbookLocator.fromJson(null))
    }
}
