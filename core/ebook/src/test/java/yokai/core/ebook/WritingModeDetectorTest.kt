package yokai.core.ebook

import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.Test

class WritingModeDetectorTest {

    private fun doc(htmlAttrs: String = "", body: String = "<p>文字</p>") =
        """<html xmlns="http://www.w3.org/1999/xhtml" $htmlAttrs><head><title>t</title></head><body>$body</body></html>""".toByteArray()

    private fun detect(
        css: List<String> = emptyList(),
        docs: List<ByteArray> = listOf(doc()),
        pwm: String? = null,
        direction: ReadingDirection = ReadingDirection.DEFAULT,
        languages: List<String> = listOf("zh-Hant"),
    ) = WritingModeDetector.detect(css.asSequence(), docs.asSequence(), pwm, direction, languages)

    @Test
    fun `Calibre's horizontal-rl filler does not override vertical CSS on the root`() {
        // What Calibre produces for a vertical, right-to-left EPUB without primary-writing-mode.
        detect(
            css = listOf(".calibre { -epub-writing-mode: vertical-rl; writing-mode: vertical-rl }"),
            docs = listOf(doc("class=\"calibre\"")),
            pwm = "horizontal-rl",
            direction = ReadingDirection.RTL,
        ) shouldBe WritingModeHint.VERTICAL
    }

    @Test
    fun `inline style and element selectors on html or body count`() {
        detect(docs = listOf(doc("style=\"writing-mode: vertical-rl\""))) shouldBe WritingModeHint.VERTICAL
        detect(css = listOf("body { -webkit-writing-mode: vertical-rl }")) shouldBe WritingModeHint.VERTICAL
        detect(docs = listOf(doc(body = "<p>x</p>").toString(Charsets.UTF_8).replace("<head>", "<head><style>html{writing-mode:tb-rl}</style>").toByteArray())) shouldBe
            WritingModeHint.VERTICAL
    }

    @Test
    fun `vertical metadata is used when the CSS says nothing about the root`() {
        detect(pwm = "vertical-rl") shouldBe WritingModeHint.VERTICAL
        detect(pwm = "horizontal-lr") shouldBe WritingModeHint.HORIZONTAL
    }

    @Test
    fun `an explicitly horizontal root wins over the right-to-left CJK fallback`() {
        detect(
            css = listOf("html { writing-mode: horizontal-tb }", "div.title { writing-mode: vertical-rl }"),
            direction = ReadingDirection.RTL,
        ) shouldBe WritingModeHint.HORIZONTAL
    }

    @Test
    fun `right-to-left CJK books with vertical rules elsewhere are vertical`() {
        val css = listOf("div.main { writing-mode: vertical-rl }")
        detect(css = css, direction = ReadingDirection.RTL) shouldBe WritingModeHint.VERTICAL
        detect(css = css, direction = ReadingDirection.RTL, pwm = "horizontal-rl") shouldBe WritingModeHint.VERTICAL
        detect(css = css, direction = ReadingDirection.LTR) shouldBe WritingModeHint.HORIZONTAL
        detect(css = css, direction = ReadingDirection.RTL, languages = listOf("ar")) shouldBe WritingModeHint.HORIZONTAL
    }

    @Test
    fun `no evidence means horizontal`() {
        detect() shouldBe WritingModeHint.HORIZONTAL
        detect(docs = listOf("not xml at all <<<".toByteArray())) shouldBe WritingModeHint.HORIZONTAL
    }
}
