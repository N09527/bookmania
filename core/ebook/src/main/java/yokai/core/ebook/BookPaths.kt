package yokai.core.ebook

import java.io.ByteArrayOutputStream

/** Helpers for container paths (ZIP entry names) and the relative URLs books use to point at them. */
object BookPaths {

    /** Directory part of a container path, without the trailing slash ("" for the root). */
    fun dirOf(path: String): String = path.substringBeforeLast('/', "")

    /** Splits `a/b.xhtml#frag` into the path and the fragment (without '#'). */
    fun splitFragment(href: String): Pair<String, String?> {
        val i = href.indexOf('#')
        return if (i < 0) href to null else href.substring(0, i) to href.substring(i + 1).ifEmpty { null }
    }

    /** True for URLs that leave the book (http:, mailto:, data:, javascript: …). */
    fun isExternal(href: String): Boolean {
        val scheme = href.trim().substringBefore(':', "")
        return scheme.isNotEmpty() && scheme.length < href.trim().length && scheme.all { it.isLetterOrDigit() || it == '+' || it == '-' || it == '.' } &&
            scheme.first().isLetter()
    }

    /**
     * Resolves a relative, percent-encoded [href] against the directory of [basePath].
     * Returns a decoded container path with its `#fragment` kept, or null when the link is
     * external or climbs above the container root.
     */
    fun resolve(basePath: String, href: String): String? {
        val trimmed = href.trim()
        if (trimmed.isEmpty() || isExternal(trimmed)) return null
        val (pathPart, fragment) = splitFragment(trimmed)
        val decoded = percentDecode(pathPart.substringBefore('?'))
        val joined = when {
            decoded.isEmpty() -> basePath
            decoded.startsWith("/") -> decoded.trimStart('/')
            else -> {
                val dir = dirOf(basePath)
                if (dir.isEmpty()) decoded else "$dir/$decoded"
            }
        }
        val normalized = normalize(joined) ?: return null
        return if (fragment != null) "$normalized#$fragment" else normalized
    }

    /** Resolves `.` and `..`; returns null if the path climbs above the root. */
    fun normalize(path: String): String? {
        val out = ArrayList<String>()
        for (seg in path.replace('\\', '/').split('/')) {
            when (seg) {
                "", "." -> Unit
                ".." -> if (out.isEmpty()) return null else out.removeAt(out.lastIndex)
                else -> out.add(seg)
            }
        }
        return out.joinToString("/")
    }

    /** Percent-decoding as UTF-8 (a '+' stays a '+': these are paths, not form data). */
    fun percentDecode(s: String): String {
        if ('%' !in s) return s
        val out = ByteArrayOutputStream(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length && isHex(s[i + 1]) && isHex(s[i + 2])) {
                out.write(s.substring(i + 1, i + 3).toInt(16))
                i += 3
            } else {
                out.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
        }
        return out.toString("UTF-8")
    }

    /** Percent-encodes a container path for use in a URL (keeps '/'). */
    fun percentEncodePath(path: String): String {
        val sb = StringBuilder()
        for (b in path.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xFF
            val ch = c.toChar()
            if (ch.isLetterOrDigit() && c < 0x80 || ch in "-._~/!$&'()*+,;=:@") sb.append(ch)
            else sb.append('%').append("%02X".format(c))
        }
        return sb.toString()
    }

    private fun isHex(c: Char) = c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'
}
