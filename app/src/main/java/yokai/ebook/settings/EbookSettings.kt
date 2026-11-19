package yokai.ebook.settings

import java.util.Locale
import kotlin.math.roundToInt

/**
 * Typesetting settings of the text reader (design section 5.6, agreed by the user).
 * Lengths are CSS px, which equal dp in the reader's WebView.
 *
 * Settings come in three levels, nearest wins: global → work (Local Source folder) → file.
 * Each level is a map of [Key] to string values; a level only holds the keys it overrides.
 * [BOOK] means "use the book's own styles" where the table allows it.
 */
data class EbookSettings(
    /** [FONT_BOOK], [FONT_SANS], [FONT_SERIF] or the id of an imported font. */
    val font: String = FONT_BOOK,
    val fontSize: Int = 20,
    val lineHeight: Float = 1.8f,
    val letterSpacing: Float = 0f,
    /** First-line indent in em; null = the book's. */
    val indent: Float? = null,
    /** Space after paragraphs in em; null = the book's. */
    val paragraphSpacing: Float? = null,
    val marginTop: Int = 32,
    val marginBottom: Int = 32,
    val marginLeft: Int = 20,
    val marginRight: Int = 20,
    /** [BOOK], [MODE_VERTICAL] or [MODE_HORIZONTAL]. */
    val writingMode: String = BOOK,
    /** [DIRECTION_AUTO] (vertical: right-to-left, horizontal: left-to-right), [DIRECTION_RTL] or [DIRECTION_LTR]. */
    val pageDirection: String = DIRECTION_AUTO,
) {
    enum class Key(val id: String) {
        FONT("font"),
        FONT_SIZE("fontSize"),
        LINE_HEIGHT("lineHeight"),
        LETTER_SPACING("letterSpacing"),
        INDENT("indent"),
        PARAGRAPH_SPACING("paragraphSpacing"),
        MARGIN_TOP("marginTop"),
        MARGIN_BOTTOM("marginBottom"),
        MARGIN_LEFT("marginLeft"),
        MARGIN_RIGHT("marginRight"),
        WRITING_MODE("writingMode"),
        PAGE_DIRECTION("pageDirection"),
        ;

        companion object {
            fun of(id: String) = entries.firstOrNull { it.id == id }
        }
    }

    /** Whether pages turn right-to-left (next page on the left), given the resolved writing mode. */
    fun rightToLeft(vertical: Boolean): Boolean = when (pageDirection) {
        DIRECTION_RTL -> true
        DIRECTION_LTR -> false
        else -> vertical
    }

    fun toMap(): Map<String, String> = linkedMapOf(
        Key.FONT.id to font,
        Key.FONT_SIZE.id to fontSize.toString(),
        Key.LINE_HEIGHT.id to format(lineHeight),
        Key.LETTER_SPACING.id to format(letterSpacing),
        Key.INDENT.id to (indent?.let(::format) ?: BOOK),
        Key.PARAGRAPH_SPACING.id to (paragraphSpacing?.let(::format) ?: BOOK),
        Key.MARGIN_TOP.id to marginTop.toString(),
        Key.MARGIN_BOTTOM.id to marginBottom.toString(),
        Key.MARGIN_LEFT.id to marginLeft.toString(),
        Key.MARGIN_RIGHT.id to marginRight.toString(),
        Key.WRITING_MODE.id to writingMode,
        Key.PAGE_DIRECTION.id to pageDirection,
    )

    companion object {
        const val BOOK = "book"
        const val FONT_BOOK = BOOK
        const val FONT_SANS = "sans"
        const val FONT_SERIF = "serif"
        const val MODE_VERTICAL = "vertical"
        const val MODE_HORIZONTAL = "horizontal"
        const val DIRECTION_AUTO = "auto"
        const val DIRECTION_RTL = "rtl"
        const val DIRECTION_LTR = "ltr"

        val DEFAULTS = EbookSettings()

        /** Ranges and steps of the settings table (section 5.6). */
        object Range {
            val fontSize = 12..48
            val lineHeight = 1.0f..3.0f
            const val LINE_HEIGHT_STEP = 0.1f
            val letterSpacing = 0f..0.5f
            const val LETTER_SPACING_STEP = 0.05f
            val indent = 0f..4f
            const val INDENT_STEP = 0.5f
            val paragraphSpacing = 0f..3f
            const val PARAGRAPH_SPACING_STEP = 0.1f
            val margin = 0..120
            const val MARGIN_STEP = 2
        }

        /** Merges the levels (later wins) and parses the result; invalid values fall back to the defaults. */
        fun resolve(vararg levels: Map<String, String>): EbookSettings {
            val merged = HashMap<String, String>()
            levels.forEach { merged.putAll(it) }
            return parse(merged)
        }

        fun parse(values: Map<String, String>): EbookSettings {
            val d = DEFAULTS
            fun str(k: Key) = values[k.id]?.trim()
            return EbookSettings(
                font = str(Key.FONT)?.takeIf { it.isNotEmpty() && FONT_ID.matches(it) } ?: d.font,
                fontSize = str(Key.FONT_SIZE)?.toIntOrNull()?.coerceIn(Range.fontSize) ?: d.fontSize,
                lineHeight = stepped(str(Key.LINE_HEIGHT), Range.lineHeight, Range.LINE_HEIGHT_STEP) ?: d.lineHeight,
                letterSpacing = stepped(str(Key.LETTER_SPACING), Range.letterSpacing, Range.LETTER_SPACING_STEP) ?: d.letterSpacing,
                indent = optional(str(Key.INDENT), Range.indent, Range.INDENT_STEP, d.indent),
                paragraphSpacing = optional(str(Key.PARAGRAPH_SPACING), Range.paragraphSpacing, Range.PARAGRAPH_SPACING_STEP, d.paragraphSpacing),
                marginTop = margin(str(Key.MARGIN_TOP)) ?: d.marginTop,
                marginBottom = margin(str(Key.MARGIN_BOTTOM)) ?: d.marginBottom,
                marginLeft = margin(str(Key.MARGIN_LEFT)) ?: d.marginLeft,
                marginRight = margin(str(Key.MARGIN_RIGHT)) ?: d.marginRight,
                writingMode = str(Key.WRITING_MODE)?.takeIf { it in setOf(BOOK, MODE_VERTICAL, MODE_HORIZONTAL) } ?: d.writingMode,
                pageDirection = str(Key.PAGE_DIRECTION)?.takeIf { it in setOf(DIRECTION_AUTO, DIRECTION_RTL, DIRECTION_LTR) }
                    ?: d.pageDirection,
            )
        }

        /** Imported fonts are referenced by a 32-character hexadecimal id. */
        private val FONT_ID = Regex("""book|sans|serif|[0-9a-f]{32}""")

        private fun stepped(text: String?, range: ClosedFloatingPointRange<Float>, step: Float): Float? {
            val v = text?.toFloatOrNull()?.takeIf { it.isFinite() } ?: return null
            val snapped = (v.coerceIn(range.start, range.endInclusive) / step).roundToInt() * step
            return (Math.round(snapped * 100f) / 100f).coerceIn(range.start, range.endInclusive)
        }

        private fun optional(text: String?, range: ClosedFloatingPointRange<Float>, step: Float, default: Float?): Float? = when {
            text == null -> default
            text == BOOK -> null
            else -> stepped(text, range, step) ?: default
        }

        private fun margin(text: String?): Int? {
            val v = text?.toIntOrNull() ?: return null
            val c = v.coerceIn(Range.margin)
            return (c / Range.MARGIN_STEP) * Range.MARGIN_STEP
        }

        fun format(value: Float): String = String.format(Locale.ROOT, "%.2f", value).trimEnd('0').trimEnd('.')
    }
}
