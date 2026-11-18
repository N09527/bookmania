package yokai.core.ebook

import java.io.ByteArrayInputStream
import org.jsoup.Jsoup
import org.jsoup.nodes.DataNode
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.jsoup.parser.Parser

/**
 * Turns a book document into safe markup for the reader's WebView.
 *
 * XHTML documents are parsed as XML, which keeps their structure (self-closing elements,
 * CDATA, named entities); `text/html` documents (MOBI 6 sections) are parsed as HTML, which
 * understands `<br>` and `<img>` without a closing slash. Both are cleaned and written out as
 * HTML5 (`<!DOCTYPE html>`, served as text/html). The writer emits explicit end tags, so `<title/>` or `<a id="x"/>` keep their
 * meaning, and malformed XHTML never ends up as an XML error page.
 *
 * Scripts can never run in the reader (sandboxed frames and a strict CSP); removing them here
 * is one more layer. SVG documents are kept as SVG.
 */
object XhtmlSanitizer {

    data class Result(val text: String, val mediaType: String)

    /** Removed together with their content. */
    private val DROP = setOf(
        "script", "iframe", "frame", "frameset", "embed", "applet", "base", "portal",
        "form", "input", "button", "select", "textarea", "option", "datalist", "keygen",
    )

    /** Removed, but their children are kept (fallback content). */
    private val UNWRAP = setOf("object")

    private val VOID = setOf("area", "br", "col", "hr", "img", "link", "meta", "source", "track", "wbr", "param")

    private val RAW_TEXT = setOf("style")

    private val URL_ATTRS = setOf(
        "href", "src", "xlink:href", "action", "formaction", "poster", "background", "data",
        "cite", "longdesc", "srcset", "lowsrc", "dynsrc", "usemap", "manifest", "ping",
    )

    private val BAD_URL = Regex("^(?:javascript|vbscript|livescript|data:(?:text/html|application/(?:x-)?(?:xhtml|javascript|ecmascript)))", RegexOption.IGNORE_CASE)

    fun sanitize(bytes: ByteArray, isHtml: Boolean = false): Result {
        val parser = if (isHtml) Parser.htmlParser() else Parser.xmlParser()
        val doc = Jsoup.parse(ByteArrayInputStream(bytes), null, "", parser)
        val root = doc.children().firstOrNull() ?: return Result(EMPTY, "text/html")
        clean(root)
        return if (root.local() == "svg") {
            doc.outputSettings().syntax(Document.OutputSettings.Syntax.xml).prettyPrint(false).charset(Charsets.UTF_8)
            Result("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.outerHtml(), "image/svg+xml")
        } else {
            val html = if (root.local() == "html") root else wrapInHtml(root)
            val sb = StringBuilder(bytes.size + 64).append("<!DOCTYPE html>\n")
            write(html, sb)
            Result(sb.toString(), "text/html")
        }
    }

    private const val EMPTY = "<!DOCTYPE html>\n<html><head></head><body></body></html>"

    private fun wrapInHtml(fragment: Element): Element {
        val html = Element("html")
        html.appendElement("head")
        html.appendElement("body").appendChild(fragment.clone())
        return html
    }

    private fun clean(root: Element) {
        // Collect first, then modify, so the traversal is not disturbed.
        val all = root.getAllElements().toList()
        for (el in all) {
            if (el.parent() == null && el !== root) continue
            val name = el.local()
            when {
                name in DROP -> { el.remove(); continue }
                name == "meta" && el.hasAttr("http-equiv") -> { el.remove(); continue }
                name == "link" && !isStylesheetLink(el) -> { el.remove(); continue }
            }
            // Attributes
            val attrs = el.attributes().asList().map { it.key }
            for (key in attrs) {
                val k = key.lowercase()
                val v = el.attr(key)
                if (k.startsWith("on") || k == "srcdoc" || k == "formaction") {
                    el.removeAttr(key)
                } else if (k in URL_ATTRS && BAD_URL.containsMatchIn(v.filterNot { it.isWhitespace() || it.isISOControl() })) {
                    el.removeAttr(key)
                }
            }
            // HTML only honours `lang`; XHTML books often only set `xml:lang`. CJK glyph choice
            // (punctuation position in vertical text) depends on it.
            if (el.hasAttr("xml:lang") && !el.hasAttr("lang")) el.attr("lang", el.attr("xml:lang"))
            if (name in RAW_TEXT) {
                val css = el.childNodes().joinToString("") {
                    when (it) {
                        is DataNode -> it.wholeData
                        is TextNode -> it.wholeText
                        else -> ""
                    }
                }
                el.empty()
                el.appendChild(DataNode(css))
            }
        }
        for (el in root.getAllElements().toList()) {
            if (el.local() in UNWRAP && el.parent() != null) el.unwrap()
        }
    }

    private fun isStylesheetLink(el: Element): Boolean {
        val rel = el.attr("rel").lowercase().split(' ', '\t', '\n')
        val href = el.attr("href").trim()
        return "stylesheet" in rel && href.isNotEmpty() && !BookPaths.isExternal(href)
    }

    private fun write(node: Node, sb: StringBuilder) {
        when (node) {
            is Element -> {
                val name = node.tagName()
                sb.append('<').append(name)
                for (a in node.attributes()) {
                    sb.append(' ').append(a.key).append("=\"")
                    escape(a.value, sb, attribute = true)
                    sb.append('"')
                }
                sb.append('>')
                val local = node.local()
                if (local in VOID && node.childNodeSize() == 0) return
                for (child in node.childNodes()) write(child, sb)
                sb.append("</").append(name).append('>')
            }
            is DataNode -> sb.append(node.wholeData.replace("</", "<\\/"))
            is TextNode -> escape(node.wholeText, sb, attribute = false)
            else -> Unit // comments, processing instructions, doctype
        }
    }

    private fun escape(s: String, sb: StringBuilder, attribute: Boolean) {
        for (c in s) {
            when (c) {
                '&' -> sb.append("&amp;")
                '<' -> sb.append("&lt;")
                '>' -> sb.append("&gt;")
                '"' -> if (attribute) sb.append("&quot;") else sb.append(c)
                else -> sb.append(c)
            }
        }
    }

    private fun Element.local(): String = tagName().substringAfter(':').lowercase()
}
