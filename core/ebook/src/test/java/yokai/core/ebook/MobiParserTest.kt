package yokai.core.ebook

import io.kotest.matchers.shouldBe
import org.jsoup.Jsoup
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import yokai.core.ebook.mobi.Mobi6Publication

class MobiParserTest {

    private fun open(name: String) = BookOpener.open(Fixtures.source(name), name.substringAfterLast('.'))

    /** Text of all spine documents, in reading order. */
    private fun allText(pub: Publication): String = pub.spine.joinToString("\n") { item ->
        val bytes = pub.open(item.href)!!.use { it.readBytes() }
        Jsoup.parse(bytes.toString(Charsets.UTF_8)).text()
    }

    /** Every paragraph marker 【第N段】 (N = 1..count) appears exactly once, in order. */
    private fun assertParagraphsComplete(text: String, count: Int) {
        val fw = "０１２３４５６７８９"
        val found = Regex("【第([０-９]+)段】").findAll(text).map { m ->
            m.groupValues[1].map { fw.indexOf(it) }.joinToString("").toInt()
        }.toList()
        found shouldBe (1..count).toList()
    }

    @Test
    fun `AZW3 (KF8) is rebuilt completely`() {
        open("zh-horizontal.azw3").use { pub ->
            pub.format shouldBe BookFormat.KF8
            pub.metadata.title shouldBe "橫排測試書"
            pub.metadata.authors shouldBe listOf("Bookmania 測試")
            (pub.spine.size >= 3) shouldBe true
            pub.writingModeHint shouldBe WritingModeHint.HORIZONTAL
            assertParagraphsComplete(allText(pub), 120)
            pub.toc.map { it.title } shouldBe listOf("第1章", "第2章", "第3章")
            pub.toc.all { it.href != null && pub.open(it.href!!) != null } shouldBe true
            ContentClassifier.classify(pub) shouldBe ContentKind.TEXT
        }
    }

    @Test
    fun `vertical AZW3 keeps direction and writing mode`() {
        open("zh-vertical.azw3").use { pub ->
            pub.format shouldBe BookFormat.KF8
            pub.readingDirection shouldBe ReadingDirection.RTL
            pub.writingModeHint shouldBe WritingModeHint.VERTICAL
            assertParagraphsComplete(allText(pub), 120)
            // every kindle: link is rewritten to a book path, and those paths resolve
            for (item in pub.spine) {
                val html = pub.open(item.href)!!.readBytes().toString(Charsets.UTF_8)
                ("kindle:" in html) shouldBe false
                for (m in Regex("""(?:src|href)="\.\./((?:images|styles|fonts)/[^"#]+)"""").findAll(html)) {
                    (pub.open(m.groupValues[1]) != null) shouldBe true
                }
            }
            pub.metadata.coverHref?.let { pub.open(it) != null } shouldBe true
        }
    }

    @Test
    fun `joint MOBI uses its KF8 part`() {
        open("zh-vertical-joint.mobi").use { pub ->
            pub.format shouldBe BookFormat.KF8
            assertParagraphsComplete(allText(pub), 120)
        }
    }

    @Test
    fun `MOBI 6 is split into sections with all text`() {
        open("zh-horizontal-mobi6.mobi").use { pub ->
            pub.format shouldBe BookFormat.MOBI
            pub.metadata.title shouldBe "橫排測試書"
            (pub.spine.size >= 3) shouldBe true
            assertParagraphsComplete(allText(pub), 120)
        }
    }

    @Test
    fun `MOBI 6 images are rewritten to book paths`() {
        open("text-with-images-mobi6.mobi").use { pub ->
            val html = pub.spine.joinToString("") { pub.open(it.href)!!.readBytes().toString(Charsets.UTF_8) }
            val srcs = Regex("""src="\.\./(images/\d{5}\.\w+)"""").findAll(html).map { it.groupValues[1] }.toList()
            (srcs.size >= 3) shouldBe true
            for (src in srcs) {
                val bytes = pub.open(src)!!.readBytes()
                (bytes.size > 100) shouldBe true
            }
        }
    }

    @Test
    fun `MOBI 6 paragraph width and height become CSS`() {
        Mobi6Publication.mobiBlockStyle("""<p height="11pt" width="1em">""") shouldBe
            """<p style="text-indent: 1em; -webkit-margin-before: 11pt; margin-block-start: 11pt;">"""
        Mobi6Publication.mobiBlockStyle("""<p height="0pt" width="-2em" style="color:red">""") shouldBe
            """<p style="text-indent: -2em; -webkit-margin-start: 2em; margin-inline-start: 2em; color:red">"""
        Mobi6Publication.mobiBlockStyle("""<div width="20">""") shouldBe """<div width="20">"""
        open("zh-horizontal-mobi6.mobi").use { pub ->
            val html = pub.open(pub.spine[1].href)!!.readBytes().toString(Charsets.UTF_8)
            ("text-indent: 1em" in html) shouldBe true
            Regex("""<p[^>]*\swidth=""").containsMatchIn(html) shouldBe false
        }
    }

    @Test
    fun `DRM flagged MOBI is refused`() {
        assertThrows<DrmProtectedException> { open("drm-flagged.mobi") }
    }
}
