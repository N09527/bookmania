package yokai.core.ebook

import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.Test

class BookStatsTest {

    @Test
    fun `character counts per document, the same for the three vertical formats`() {
        // The reader shell counts the same characters (non-whitespace text, ruby included): for the
        // first chapter of zh-vertical.epub it reported 1880 in the desktop check of stage 5.
        val epub = BookOpener.open(Fixtures.source("zh-vertical.epub"), "epub").use { BookStats.charCounts(it) }
        epub.toList() shouldBe listOf(1880, 1847, 1872)
        BookOpener.open(Fixtures.source("zh-vertical.azw3"), "azw3").use { BookStats.charCounts(it).toList() } shouldBe epub.toList()
        BookOpener.open(Fixtures.source("zh-vertical-joint.mobi"), "mobi").use { BookStats.charCounts(it).toList() } shouldBe epub.toList()
    }

    @Test
    fun `only text counts`() {
        BookStats.countText("<html><body><p>　漢 字\n<b>ab</b></p><img src='a.png'/></body></html>".toByteArray()) shouldBe 4
        BookStats.countText("<html><body></body></html>".toByteArray()) shouldBe 0
    }
}
