package yokai.core.ebook.font

/** Result of reading an imported font file. */
data class FontInfo(
    /** Family name for display; null when the font has no usable name. */
    val familyName: String?,
    val format: FontFormat,
    /** `vhea` and `vmtx` tables: advances and origins for vertical layout. */
    val hasVerticalMetrics: Boolean,
    /** A GSUB `vert` or `vrt2` feature: vertical forms of punctuation and brackets. */
    val hasVerticalGlyphs: Boolean,
) {
    /** True when the font is expected to typeset vertical text properly. */
    val supportsVertical: Boolean get() = hasVerticalMetrics && hasVerticalGlyphs
}

enum class FontFormat(val extension: String) { TRUETYPE("ttf"), OPENTYPE_CFF("otf") }

class InvalidFontException(message: String) : Exception(message)

/**
 * Reads the table directory of a TrueType / OpenType font (no rendering). Font collections (.ttc),
 * WOFF and WOFF2 are refused: the reader only imports single TTF / OTF files.
 */
object FontInspector {

    private const val MAX_TABLES = 512

    fun inspect(bytes: ByteArray): FontInfo {
        if (bytes.size < 12) throw InvalidFontException("File too small for a font")
        val format = when (val tag = u32(bytes, 0)) {
            0x00010000L, TRUE -> FontFormat.TRUETYPE
            OTTO -> FontFormat.OPENTYPE_CFF
            TTCF -> throw InvalidFontException("Font collections (.ttc) are not supported")
            WOFF, WOF2 -> throw InvalidFontException("WOFF fonts are not supported")
            else -> throw InvalidFontException("Not a TrueType or OpenType font (0x${tag.toString(16)})")
        }
        val numTables = u16(bytes, 4)
        if (numTables == 0 || numTables > MAX_TABLES) throw InvalidFontException("Bad table count $numTables")
        val tables = HashMap<String, IntRange>()
        for (i in 0 until numTables) {
            val p = 12 + i * 16
            if (p + 16 > bytes.size) throw InvalidFontException("Truncated table directory")
            val tag = String(bytes, p, 4, Charsets.ISO_8859_1)
            val offset = u32(bytes, p + 8)
            val length = u32(bytes, p + 12)
            if (offset + length > bytes.size) throw InvalidFontException("Table $tag lies outside the file")
            tables[tag] = offset.toInt() until (offset + length).toInt()
        }
        val required = if (format == FontFormat.TRUETYPE) listOf("cmap", "glyf", "loca") else listOf("cmap", "CFF ")
        val missing = required.filter { it !in tables && !(it == "CFF " && "CFF2" in tables) }
        if (missing.isNotEmpty()) throw InvalidFontException("Missing tables: ${missing.joinToString()}")

        return FontInfo(
            familyName = tables["name"]?.let { runCatching { familyName(bytes, it) }.getOrNull() },
            format = format,
            hasVerticalMetrics = "vhea" in tables && "vmtx" in tables,
            hasVerticalGlyphs = tables["GSUB"]?.let { runCatching { hasFeature(bytes, it, setOf("vert", "vrt2")) }.getOrNull() } == true,
        )
    }

    private fun hasFeature(b: ByteArray, gsub: IntRange, tags: Set<String>): Boolean {
        val base = gsub.first
        val featureList = base + u16(b, base + 6)
        if (featureList !in gsub) return false
        val count = u16(b, featureList)
        for (i in 0 until count) {
            val p = featureList + 2 + i * 6
            if (p + 6 > gsub.last + 1) return false
            if (String(b, p, 4, Charsets.ISO_8859_1) in tags) return true
        }
        return false
    }

    /**
     * Prefers the typographic family (ID 16) over the legacy family (ID 1), Windows / Unicode
     * records over Mac ones, and Traditional Chinese, then other Chinese, then English, then any.
     */
    private fun familyName(b: ByteArray, name: IntRange): String? {
        val base = name.first
        val count = u16(b, base + 2)
        val storage = base + u16(b, base + 4)
        data class Candidate(val text: String, val score: Int)
        val candidates = ArrayList<Candidate>()
        for (i in 0 until count) {
            val p = base + 6 + i * 12
            if (p + 12 > name.last + 1) break
            val platform = u16(b, p)
            val encoding = u16(b, p + 2)
            val language = u16(b, p + 4)
            val nameId = u16(b, p + 6)
            val length = u16(b, p + 8)
            val offset = storage + u16(b, p + 10)
            if (nameId != 1 && nameId != 16) continue
            if (offset + length > name.last + 1) continue
            val text = when {
                platform == 3 && (encoding == 1 || encoding == 10) || platform == 0 ->
                    String(b, offset, length, Charsets.UTF_16BE)
                platform == 1 && encoding == 0 -> String(b, offset, length, Charsets.ISO_8859_1)
                else -> continue
            }.trim().ifEmpty { continue }
            val languageScore = when {
                platform == 3 && language == 0x0404 -> 40 // zh-TW
                platform == 3 && language in setOf(0x0C04, 0x1404) -> 35 // zh-HK, zh-MO
                platform == 3 && language in setOf(0x0804, 0x1004) -> 30 // zh-CN, zh-SG
                platform == 3 && language == 0x0409 -> 20 // en-US
                platform == 0 -> 10
                else -> 5
            }
            candidates.add(Candidate(text, languageScore + if (nameId == 16) 1 else 0))
        }
        return candidates.maxByOrNull { it.score }?.text
    }

    private fun u16(b: ByteArray, i: Int): Int {
        if (i < 0 || i + 2 > b.size) throw InvalidFontException("Read outside the font")
        return ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
    }

    private fun u32(b: ByteArray, i: Int): Long {
        if (i < 0 || i + 4 > b.size) throw InvalidFontException("Read outside the font")
        return ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
            ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)
    }

    private const val TRUE = 0x74727565L // 'true' (old Apple TrueType)
    private const val OTTO = 0x4F54544FL // 'OTTO'
    private const val TTCF = 0x74746366L // 'ttcf'
    private const val WOFF = 0x774F4646L // 'wOFF'
    private const val WOF2 = 0x774F4632L // 'wOF2'
}
