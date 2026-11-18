package yokai.core.ebook

import yokai.core.ebook.io.RandomAccessSource

/** Identifies a book file from its first bytes (the extension is only a hint). */
object FormatDetector {

    fun detect(source: RandomAccessSource, extension: String? = null): BookFormat {
        val size = source.size
        if (size < 4) return BookFormat.UNKNOWN
        val head = source.read(0, minOf(size, 128L).toInt())
        val ext = extension?.lowercase()

        if (head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte() && head[2] == 3.toByte() && head[3] == 4.toByte()) {
            // OCF requires an uncompressed "mimetype" entry first; many books ignore that, so the
            // extension is accepted as well. A damaged EPUB is still reported as EPUB here; the
            // parser then explains that it is damaged.
            val nameLen = if (head.size >= 30) (head[26].toInt() and 0xFF) or ((head[27].toInt() and 0xFF) shl 8) else 0
            val firstName = if (head.size >= 30 + nameLen) String(head, 30, nameLen, Charsets.ISO_8859_1) else ""
            if (firstName == "mimetype" || ext == "epub") return BookFormat.EPUB
            return BookFormat.UNKNOWN
        }
        if (size >= 68) {
            when (String(head, 60, 8, Charsets.ISO_8859_1)) {
                "BOOKMOBI", "TEXtREAd" -> return BookFormat.MOBI
            }
        }
        // KFX containers ("CONT") and DRM-wrapped KFX ("êDRMIONî") are not supported.
        if (String(head, 0, 4, Charsets.ISO_8859_1) == "CONT") return BookFormat.KFX
        if (head.size >= 8 && head[0] == 0xEA.toByte() && String(head, 1, 6, Charsets.ISO_8859_1) == "DRMION") return BookFormat.KFX
        return BookFormat.UNKNOWN
    }
}
