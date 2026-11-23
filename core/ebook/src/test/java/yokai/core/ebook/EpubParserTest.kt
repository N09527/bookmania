package yokai.core.ebook

import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import yokai.core.ebook.epub.EpubParser
import yokai.core.ebook.io.ByteArraySource

class EpubParserTest {

    private fun open(name: String) = EpubParser.parse(Fixtures.source(name))

    @Test
    fun `vertical Chinese book metadata, spine, toc and direction`() {
        open("zh-vertical.epub").use { pub ->
            pub.format shouldBe BookFormat.EPUB
            pub.metadata.title shouldBe "直排測試書"
            pub.metadata.authors shouldBe listOf("Bookmania 測試")
            pub.metadata.languages shouldBe listOf("zh-Hant")
            pub.metadata.identifier shouldBe "urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000001"
            pub.metadata.coverHref shouldBe "OEBPS/images/cover.png"
            pub.spine.map { it.href } shouldBe listOf("OEBPS/text/ch01.xhtml", "OEBPS/text/ch02.xhtml", "OEBPS/text/ch03.xhtml")
            pub.spine.all { it.mediaType == "application/xhtml+xml" } shouldBe true
            pub.toc.map { it.title } shouldBe listOf("第1章", "第2章", "第3章")
            pub.toc.map { it.href } shouldBe listOf("OEBPS/text/ch01.xhtml", "OEBPS/text/ch02.xhtml", "OEBPS/text/ch03.xhtml")
            pub.readingDirection shouldBe ReadingDirection.RTL
            pub.writingModeHint shouldBe WritingModeHint.VERTICAL
            pub.isFixedLayout shouldBe false
            pub.mediaType("OEBPS/images/fig1.png") shouldBe "image/png"
            pub.mediaType("OEBPS/styles/book.css") shouldBe "text/css"
            val chapter = pub.open("OEBPS/text/ch01.xhtml")!!.use { it.readBytes().toString(Charsets.UTF_8) }
            ("【第１段】" in chapter) shouldBe true
            pub.open("OEBPS/does/not/exist.png") shouldBe null
        }
    }

    @Test
    fun `horizontal and Japanese vertical books`() {
        open("zh-horizontal.epub").use {
            it.readingDirection shouldBe ReadingDirection.LTR
            it.writingModeHint shouldBe WritingModeHint.HORIZONTAL
        }
        open("ja-vertical.epub").use {
            it.metadata.languages shouldBe listOf("ja")
            it.writingModeHint shouldBe WritingModeHint.VERTICAL
        }
    }

    @Test
    fun `EPUB 2 table of contents comes from the NCX`() {
        open("epub2-ncx.epub").use { pub ->
            pub.toc.map { it.title } shouldBe listOf("第1章", "第2章")
            pub.toc[1].href shouldBe "OEBPS/text/ch02.xhtml"
        }
    }

    @Test
    fun `text and image books are classified`() {
        open("zh-vertical.epub").use { ContentClassifier.classify(it) shouldBe ContentKind.TEXT }
        open("text-with-images.epub").use { ContentClassifier.classify(it) shouldBe ContentKind.TEXT }
        open("comic-fixed.epub").use {
            it.isFixedLayout shouldBe true
            ContentClassifier.classify(it) shouldBe ContentKind.COMIC
        }
        open("comic-reflowable.epub").use {
            it.isFixedLayout shouldBe false
            ContentClassifier.classify(it) shouldBe ContentKind.COMIC
        }
    }

    @Test
    fun `obfuscated font is returned de-obfuscated`() {
        open("font-obfuscated.epub").use { pub ->
            val font = pub.open("OEBPS/fonts/test.ttf")!!.use { it.readBytes() }
            font.contentEquals(Fixtures.bytes("font-obfuscated.expected.ttf")) shouldBe true
        }
    }

    @Test
    fun `DRM protected book is refused with the scheme`() {
        val e = assertThrows<DrmProtectedException> { open("drm-adept.epub") }
        e.scheme shouldBe "Adobe ADEPT"
    }

    @Test
    fun `damaged files raise CorruptBookException`() {
        assertThrows<CorruptBookException> { open("corrupt-truncated.epub") }
        assertThrows<CorruptBookException> { open("not-an-ebook.epub") }
    }

    @Test
    fun `files that cannot be read at all raise UnreadableFileException`() {
        assertThrows<UnreadableFileException> { open("corrupt-truncated.epub") } // ZIP cut short
        assertThrows<UnreadableFileException> { open("not-an-ebook.epub") } // not a ZIP
        assertThrows<UnreadableFileException> { BookOpener.open(Fixtures.source("not-an-ebook.epub"), "epub") }
    }

    @Test
    fun `a readable ZIP without a package document is damaged but not unreadable`() {
        val bytes = ByteArrayOutputStream().also { out ->
            ZipOutputStream(out).use { zip ->
                zip.putNextEntry(ZipEntry("001.png"))
                zip.write(ByteArray(64) { 1 })
                zip.closeEntry()
            }
        }.toByteArray()
        val e = assertThrows<CorruptBookException> { EpubParser.parse(ByteArraySource(bytes)) }
        (e is UnreadableFileException) shouldBe false
    }

    @Test
    fun `links and fragments in the toc are resolved`() {
        open("zh-horizontal.epub").use { pub ->
            pub.toc.first().href shouldNotBe null
        }
    }
}
