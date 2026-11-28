package yokai.core.sync

/**
 * A small XML reader for WebDAV responses, which are untrusted input: document type declarations are skipped and
 * never processed, so no entity is defined or fetched; only the five predefined entities and character references
 * are decoded. Element names are resolved to (namespace, local name).
 */
class XmlElement(val namespace: String, val name: String, val children: List<XmlElement>, val text: String) {
    fun child(namespace: String, name: String) = children.firstOrNull { it.namespace == namespace && it.name == name }
    fun all(namespace: String, name: String) = children.filter { it.namespace == namespace && it.name == name }
}

class XmlFormatException(message: String) : Exception(message)

object MiniXml {

    fun parse(xml: String): XmlElement {
        val p = Parser(xml)
        return p.document()
    }

    private class Builder(val prefix: String?, val local: String, val namespaces: Map<String, String>) {
        val children = mutableListOf<XmlElement>()
        val text = StringBuilder()
    }

    private class Parser(val s: String) {
        var i = 0

        fun document(): XmlElement {
            val stack = ArrayDeque<Builder>()
            while (i < s.length) {
                if (s[i] != '<') {
                    val end = s.indexOf('<', i).let { if (it < 0) s.length else it }
                    stack.lastOrNull()?.text?.append(decode(s.substring(i, end)))
                    i = end
                    continue
                }
                when {
                    s.startsWith("<?", i) -> i = skipPast("?>")
                    s.startsWith("<!--", i) -> i = skipPast("-->")
                    s.startsWith("<![CDATA[", i) -> {
                        val end = s.indexOf("]]>", i + 9)
                        if (end < 0) throw XmlFormatException("unterminated CDATA")
                        stack.lastOrNull()?.text?.append(s, i + 9, end)
                        i = end + 3
                    }
                    s.startsWith("<!", i) -> i = skipDeclaration()
                    s.startsWith("</", i) -> {
                        val end = s.indexOf('>', i)
                        if (end < 0) throw XmlFormatException("unterminated end tag")
                        val b = stack.removeLastOrNull() ?: throw XmlFormatException("unexpected end tag")
                        val element = finish(b)
                        i = end + 1
                        val parent = stack.lastOrNull() ?: return element
                        parent.children += element
                    }
                    else -> {
                        val (b, selfClosing) = startTag(stack.lastOrNull()?.namespaces ?: emptyMap())
                        if (selfClosing) {
                            val element = finish(b)
                            val parent = stack.lastOrNull() ?: return element
                            parent.children += element
                        } else {
                            stack.addLast(b)
                        }
                    }
                }
            }
            throw XmlFormatException("no root element")
        }

        private fun finish(b: Builder): XmlElement {
            val ns = b.namespaces[b.prefix ?: ""] ?: ""
            return XmlElement(ns, b.local, b.children.toList(), b.text.toString())
        }

        private fun skipPast(marker: String): Int {
            val end = s.indexOf(marker, i)
            if (end < 0) throw XmlFormatException("unterminated $marker")
            return end + marker.length
        }

        /** `<!DOCTYPE ...>` with an optional internal subset in brackets, skipped whole. */
        private fun skipDeclaration(): Int {
            var j = i + 2
            var depth = 0
            var quote: Char? = null
            while (j < s.length) {
                val c = s[j]
                when {
                    quote != null -> if (c == quote) quote = null
                    c == '"' || c == '\'' -> quote = c
                    c == '[' -> depth++
                    c == ']' -> depth--
                    c == '>' && depth <= 0 -> return j + 1
                }
                j++
            }
            throw XmlFormatException("unterminated declaration")
        }

        private fun startTag(inherited: Map<String, String>): Pair<Builder, Boolean> {
            i++ // '<'
            val nameStart = i
            while (i < s.length && !s[i].isWhitespace() && s[i] != '>' && s[i] != '/') i++
            val qname = s.substring(nameStart, i)
            if (qname.isEmpty()) throw XmlFormatException("empty tag name")
            val namespaces = inherited.toMutableMap()
            while (true) {
                while (i < s.length && s[i].isWhitespace()) i++
                if (i >= s.length) throw XmlFormatException("unterminated tag")
                if (s[i] == '>') {
                    i++
                    return builder(qname, namespaces) to false
                }
                if (s.startsWith("/>", i)) {
                    i += 2
                    return builder(qname, namespaces) to true
                }
                val attrStart = i
                while (i < s.length && s[i] != '=' && !s[i].isWhitespace() && s[i] != '>' && s[i] != '/') i++
                val attr = s.substring(attrStart, i)
                while (i < s.length && s[i].isWhitespace()) i++
                var value = ""
                if (i < s.length && s[i] == '=') {
                    i++
                    while (i < s.length && s[i].isWhitespace()) i++
                    val q = s.getOrNull(i) ?: throw XmlFormatException("unterminated attribute")
                    if (q == '"' || q == '\'') {
                        val end = s.indexOf(q, i + 1)
                        if (end < 0) throw XmlFormatException("unterminated attribute")
                        value = decode(s.substring(i + 1, end))
                        i = end + 1
                    } else {
                        val vs = i
                        while (i < s.length && !s[i].isWhitespace() && s[i] != '>') i++
                        value = s.substring(vs, i)
                    }
                }
                if (attr == "xmlns") namespaces[""] = value
                else if (attr.startsWith("xmlns:")) namespaces[attr.substring(6)] = value
            }
        }

        private fun builder(qname: String, namespaces: Map<String, String>): Builder {
            val colon = qname.indexOf(':')
            return if (colon < 0) {
                Builder(null, qname, namespaces)
            } else {
                Builder(qname.substring(0, colon), qname.substring(colon + 1), namespaces)
            }
        }

        private fun decode(text: String): String {
            if ('&' !in text) return text
            val out = StringBuilder(text.length)
            var j = 0
            while (j < text.length) {
                val c = text[j]
                if (c == '&') {
                    val end = text.indexOf(';', j)
                    if (end > j) {
                        val name = text.substring(j + 1, end)
                        val decoded = when {
                            name == "lt" -> "<"
                            name == "gt" -> ">"
                            name == "amp" -> "&"
                            name == "quot" -> "\""
                            name == "apos" -> "'"
                            name.startsWith("#x") || name.startsWith("#X") -> name.substring(2).toIntOrNull(16)?.let(::codePoint)
                            name.startsWith("#") -> name.substring(1).toIntOrNull()?.let(::codePoint)
                            else -> null // undefined entities stay as they are
                        }
                        if (decoded != null) {
                            out.append(decoded)
                            j = end + 1
                            continue
                        }
                    }
                }
                out.append(c)
                j++
            }
            return out.toString()
        }

        private fun codePoint(cp: Int): String? =
            if (cp in 1..0x10FFFF && cp !in 0xD800..0xDFFF) String(Character.toChars(cp)) else null
    }
}
