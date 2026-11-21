package yokai.ebook

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import yokai.ebook.data.EbookLocator

/** The page the image reader starts at for a Local Source EPUB (EbookRouter.imageReaderStartPage). */
class ImageReaderPageTest {

    private fun textPosition(chapterPage: Int, total: Double?, atEnd: Boolean = false) =
        EbookLocator(spine = 1, href = "b.xhtml", progression = 0.3, total = total, atEnd = atEnd, chapterPage = chapterPage, updatedAt = 1L)

    @Test
    fun `a text page past the pictures starts at the same fraction instead of crashing`() {
        // text reader: page 24 of 27 of a text book with one picture
        assertEquals(0, EbookRouter.imageReaderStartPage(23, 4, textPosition(23, 0.85), pageCount = 1))
    }

    @Test
    fun `a text page within the pictures is mapped too, so an early page does not land on the last picture`() {
        // page 10 of 300 in the text reader is 3 % of the book: the first of 10 pictures, not the last one
        assertEquals(0, EbookRouter.imageReaderStartPage(9, 291, textPosition(9, 0.03), pageCount = 10))
        assertEquals(1, EbookRouter.imageReaderStartPage(5, 22, textPosition(5, 0.19), pageCount = 10))
        // the end of the book is the last picture
        assertEquals(9, EbookRouter.imageReaderStartPage(26, 1, textPosition(26, 1.0, atEnd = true), pageCount = 10))
    }

    @Test
    fun `without the whole-book fraction the chapter list pages give it`() {
        assertEquals(5, EbookRouter.imageReaderStartPage(10, 10, textPosition(10, null), pageCount = 10))
    }

    @Test
    fun `the image reader's own page is kept, a page out of range starts at the first picture`() {
        // last written by the image reader: the text position's chapterPage is an older number
        assertNull(EbookRouter.imageReaderStartPage(4, 6, textPosition(12, 0.4), pageCount = 10))
        assertNull(EbookRouter.imageReaderStartPage(4, 6, null, pageCount = 10))
        assertEquals(0, EbookRouter.imageReaderStartPage(12, 6, null, pageCount = 10))
        assertEquals(0, EbookRouter.imageReaderStartPage(-1, 0, null, pageCount = 10))
        assertNull(EbookRouter.imageReaderStartPage(3, 0, null, pageCount = 0))
    }
}
