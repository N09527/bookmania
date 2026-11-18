package yokai.core.ebook

import io.kotest.matchers.shouldBe
import io.kotest.matchers.string.shouldContain
import io.kotest.matchers.string.shouldNotContain
import org.junit.jupiter.api.Test
import yokai.core.ebook.io.ByteArraySource
import yokai.core.ebook.io.ZipReader

class BookPathsTest {
    @Test
    fun `relative links resolve against the document directory`() {
        BookPaths.resolve("OEBPS/text/ch01.xhtml", "../images/fig%201.png") shouldBe "OEBPS/images/fig 1.png"
        BookPaths.resolve("OEBPS/text/ch01.xhtml", "ch02.xhtml#p2") shouldBe "OEBPS/text/ch02.xhtml#p2"
        BookPaths.resolve("OEBPS/text/ch01.xhtml", "#note1") shouldBe "OEBPS/text/ch01.xhtml#note1"
        BookPaths.resolve("OEBPS/content.opf", "/root.css") shouldBe "root.css"
        BookPaths.resolve("a.xhtml", "../../escape.png") shouldBe null
        BookPaths.resolve("a.xhtml", "https://example.com/") shouldBe null
        BookPaths.resolve("a.xhtml", "mailto:x@example.com") shouldBe null
    }

    @Test
    fun `external detection`() {
        BookPaths.isExternal("https://example.com") shouldBe true
        BookPaths.isExternal("javascript:alert(1)") shouldBe true
        BookPaths.isExternal("text/ch01.xhtml") shouldBe false
        BookPaths.isExternal("C:/x") shouldBe true
        BookPaths.isExternal("ch01.xhtml#a:b") shouldBe false
    }

    @Test
    fun `percent decoding keeps plus signs and handles UTF-8`() {
        BookPaths.percentDecode("a+b%E6%B8%AC.xhtml") shouldBe "a+b測.xhtml"
        BookPaths.percentDecode("bad%zz") shouldBe "bad%zz"
    }
}

class FormatDetectorTest {
    @Test
    fun `formats are recognised from content`() {
        for ((name, format) in listOf(
            "zh-vertical.epub" to BookFormat.EPUB,
            "corrupt-truncated.epub" to BookFormat.EPUB,
            "zh-horizontal-mobi6.mobi" to BookFormat.MOBI,
            "zh-vertical.azw3" to BookFormat.MOBI,
            "zh-vertical-joint.mobi" to BookFormat.MOBI,
        )) {
            Fixtures.source(name).use { FormatDetector.detect(it, name.substringAfterLast('.')) shouldBe format }
        }
        Fixtures.source("not-an-ebook.epub").use { FormatDetector.detect(it, "epub") shouldBe BookFormat.UNKNOWN }
        FormatDetector.detect(ByteArraySource("CONT\u0002\u0000\u0000\u0000".toByteArray(Charsets.ISO_8859_1))) shouldBe BookFormat.KFX
    }
}

class ZipReaderTest {
    @Test
    fun `entries and contents`() {
        ZipReader(Fixtures.source("zh-vertical.epub")).use { zip ->
            zip.readText("mimetype") shouldBe "application/epub+zip"
            zip.has("META-INF/container.xml") shouldBe true
            zip.has("meta-inf/CONTAINER.xml") shouldBe true // case-insensitive fallback
            zip.find("missing") shouldBe null
        }
    }

    @Test
    fun `oversized entries are refused`() {
        val reader = ZipReader(Fixtures.source("zh-vertical.epub"), ZipReader.Limits(maxEntrySize = 10))
        reader.use {
            val e = runCatching { it.readBytes("OEBPS/content.opf") }.exceptionOrNull()
            (e is CorruptBookException) shouldBe true
        }
    }
}

class XhtmlSanitizerTest {
    private fun clean(xml: String) = XhtmlSanitizer.sanitize(xml.toByteArray()).text

    @Test
    fun `scripts, handlers and javascript links are removed`() {
        val out = clean(
            """<?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title/><script>alert(1)</script></head>
            <body onload="x()"><p onclick="y()">文<a href="javascript:alert(2)">連結</a><a href=" JaVa
            Script:alert(3)">x</a><a href="ch02.xhtml#a">ok</a></p><iframe src="https://example.com/"/>
            <form action="https://e.com"><input name="q"/></form></body></html>""",
        )
        out shouldNotContain "<script"
        out shouldNotContain "alert"
        out shouldNotContain "onload"
        out shouldNotContain "onclick"
        out shouldNotContain "<iframe"
        out shouldNotContain "<form"
        out shouldContain "href=\"ch02.xhtml#a\""
        out shouldContain "<title></title>"
        out.startsWith("<!DOCTYPE html>") shouldBe true
    }

    @Test
    fun `XHTML structure survives HTML serialisation`() {
        val out = clean(
            """<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-Hant"><head>
            <style type="text/css"><![CDATA[ p > a { color: red } ]]></style></head>
            <body><p>一<br/>二<a id="anchor"/>三&#160;四</p><div/></body></html>""",
        )
        out shouldContain "p > a { color: red }"
        out shouldContain "一<br>二<a id=\"anchor\"></a>三"
        out shouldContain "<div></div>"
        out shouldContain "lang=\"zh-Hant\""
        out shouldNotContain "</br>"
    }

    @Test
    fun `object is unwrapped to its fallback and SVG documents stay SVG`() {
        clean("""<html><body><object data="x.svg" type="image/svg+xml"><img src="x.png"/></object></body></html>""") shouldContain "<img src=\"x.png\">"
        val svg = XhtmlSanitizer.sanitize(
            """<svg xmlns="http://www.w3.org/2000/svg" onload="evil()"><script>evil()</script><image href="a.png"/></svg>""".toByteArray(),
        )
        svg.mediaType shouldBe "image/svg+xml"
        svg.text shouldNotContain "evil"
    }
}
