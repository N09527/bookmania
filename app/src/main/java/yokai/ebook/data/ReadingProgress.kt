package yokai.ebook.data

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Whole-book progress of a text book from the character counts of its documents ([BookStats]) and the
 * position in the open document. Text books have no fixed pages: the chapter list's "page X of Y" is
 * an estimate with the page size of the current layout (characters per page of the open document).
 */
class ReadingProgress(private val charCounts: IntArray) {

    private val totalChars: Long = charCounts.fold(0L) { acc, n -> acc + n }

    /** Characters of the documents before [spine]. */
    private fun charsBefore(spine: Int): Long {
        var sum = 0L
        for (i in 0 until min(spine, charCounts.size)) sum += charCounts[i]
        return sum
    }

    /**
     * Fraction of the book (0..1) at [docFraction] of document [spine]. A book without any text (e.g. a
     * comic EPUB opened as text) counts each document as an equal part instead.
     */
    fun total(spine: Int, docFraction: Double): Double {
        if (spine !in charCounts.indices) return 0.0
        val f = docFraction.coerceIn(0.0, 1.0)
        if (totalChars <= 0L) return ((spine + f) / charCounts.size).coerceIn(0.0, 1.0)
        return ((charsBefore(spine) + f * charCounts[spine]) / totalChars).coerceIn(0.0, 1.0)
    }

    /** Document and fraction in it for a fraction of the book (the progress slider). */
    fun locate(total: Double): Pair<Int, Double> {
        if (charCounts.isEmpty()) return 0 to 0.0
        if (totalChars <= 0L) {
            val x = total.coerceIn(0.0, 1.0) * charCounts.size
            val index = min(charCounts.size - 1, x.toInt())
            return index to (x - index).coerceIn(0.0, 1.0)
        }
        val target = total.coerceIn(0.0, 1.0) * totalChars
        var before = 0L
        for (i in charCounts.indices) {
            val n = charCounts[i]
            if (n > 0 && target < before + n) return i to ((target - before) / n).coerceIn(0.0, 1.0)
            before += n
        }
        val last = charCounts.indexOfLast { it > 0 }.coerceAtLeast(0)
        return last to 1.0
    }

    /**
     * Page numbers for the chapter list: (index of the current page, number of pages). The open document
     * counts with its real pages ([page] of [pages] in the current layout); the other documents are
     * estimated with its page size (characters per page). Null when the open document has no text to
     * measure with.
     */
    fun pages(spine: Int, page: Int, pages: Int, atEnd: Boolean): Pair<Int, Int>? {
        val docChars = charCounts.getOrNull(spine) ?: return null
        if (docChars <= 0 || pages <= 0 || totalChars <= 0L) return null
        val charsPerPage = docChars.toDouble() / pages
        val charsBefore = charsBefore(spine)
        val before = (charsBefore / charsPerPage).roundToInt()
        val after = ((totalChars - charsBefore - docChars) / charsPerPage).roundToInt()
        val totalPages = max(1, before + pages + after)
        val current = if (atEnd) totalPages - 1 else min(totalPages - 1, before + page.coerceAtLeast(0))
        return current to totalPages
    }
}
