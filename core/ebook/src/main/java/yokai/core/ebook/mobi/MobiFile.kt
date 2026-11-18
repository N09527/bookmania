package yokai.core.ebook.mobi

import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.util.zip.Inflater
import yokai.core.ebook.CorruptBookException
import yokai.core.ebook.DrmProtectedException
import yokai.core.ebook.io.RandomAccessSource

/** Header values of one MOBI "record 0" (the MOBI 6 part or the KF8 part of a file). */
internal class MobiHeaders(record0: ByteArray) {
    val compression = be16(record0, 0)
    val numTextRecords = be16(record0, 8)
    val encryption = be16(record0, 12)
    val headerLength: Int
    val encoding: Long
    val uid: Long
    val version: Long
    val titleOffset: Int
    val titleLength: Int
    val localeLanguage: Int
    val localeRegion: Int
    val firstResource: Long
    val huffRecord: Long
    val huffCount: Long
    val exthFlags: Long
    val extraDataFlags: Int
    val ncxIndex: Long
    val fdst: Long
    val fragIndex: Long
    val skelIndex: Long
    val guideIndex: Long
    val exth: Map<Int, List<ByteArray>>
    val title: ByteArray

    init {
        if (ascii(record0, 16, 4) != "MOBI") throw CorruptBookException("Missing MOBI header")
        headerLength = be32(record0, 20).toInt()
        encoding = be32(record0, 28)
        uid = be32(record0, 32)
        version = be32(record0, 36)
        titleOffset = be32(record0, 84).toInt()
        titleLength = be32(record0, 88).toInt()
        localeRegion = record0[94].toInt() and 0xFF
        localeLanguage = record0[95].toInt() and 0xFF
        firstResource = be32or(record0, 108, NULL_INDEX)
        huffRecord = be32or(record0, 112, NULL_INDEX)
        huffCount = be32or(record0, 116, 0)
        exthFlags = be32or(record0, 128, 0)
        val headerEnd = 16 + headerLength
        extraDataFlags = if (headerLength >= 0xE4 && 244 <= record0.size) be16(record0, 242) else 0
        ncxIndex = if (headerEnd >= 248) be32or(record0, 244, NULL_INDEX) else NULL_INDEX
        val kf8 = version >= 8
        fdst = if (kf8) be32or(record0, 192, NULL_INDEX) else NULL_INDEX
        fragIndex = if (kf8) be32or(record0, 248, NULL_INDEX) else NULL_INDEX
        skelIndex = if (kf8) be32or(record0, 252, NULL_INDEX) else NULL_INDEX
        guideIndex = if (kf8) be32or(record0, 260, NULL_INDEX) else NULL_INDEX
        exth = if (exthFlags and 0x40 != 0L) readExth(record0, headerEnd) else emptyMap()
        title = if (titleOffset in 0 until record0.size) {
            record0.copyOfRange(titleOffset, minOf(record0.size, titleOffset + maxOf(0, titleLength)))
        } else {
            ByteArray(0)
        }
    }

    val charset: Charset get() = if (encoding == 65001L) Charsets.UTF_8 else Charset.forName("windows-1252")

    fun exthString(type: Int): String? = exth[type]?.firstOrNull()?.toString(charset)?.trim()?.ifEmpty { null }
    fun exthStrings(type: Int): List<String> = exth[type].orEmpty().map { it.toString(charset).trim() }.filter { it.isNotEmpty() }
    fun exthUint(type: Int): Long? = exth[type]?.firstOrNull()?.let { b ->
        var v = 0L
        for (x in b) v = (v shl 8) or (x.toLong() and 0xFF)
        v
    }

    private fun readExth(record0: ByteArray, start: Int): Map<Int, List<ByteArray>> {
        if (ascii(record0, start, 4) != "EXTH") return emptyMap()
        val count = be32(record0, start + 8)
        val out = HashMap<Int, MutableList<ByteArray>>()
        var p = start + 12
        for (i in 0 until count) {
            if (p + 8 > record0.size) break
            val type = be32(record0, p).toInt()
            val length = be32(record0, p + 4).toInt()
            if (length < 8 || p + length > record0.size) break
            out.getOrPut(type) { ArrayList() }.add(record0.copyOfRange(p + 8, p + length))
            p += length
        }
        return out
    }
}

/**
 * A MOBI/KF8 file: PDB record table plus the headers of the part that will be read.
 * For "joint" files (MOBI 6 + KF8) the KF8 part is used, like Kindle devices do.
 */
internal class MobiFile(private val source: RandomAccessSource) {
    private val offsets: LongArray
    val numRecords: Int

    /** Headers of the first record 0 (the MOBI 6 part in joint files). */
    val baseHeaders: MobiHeaders

    /** Headers of the part being read. */
    val headers: MobiHeaders

    /** Record index of the part's record 0 (0, or the KF8 boundary). */
    val start: Int

    val isKf8: Boolean

    /** Absolute record index of resource #1 (images, fonts …). */
    val resourceStart: Long

    init {
        if (source.size < 86) throw CorruptBookException("File too small for a MOBI book")
        val head = source.read(0, 78)
        numRecords = be16(head, 76)
        if (numRecords < 2) throw CorruptBookException("No records in the MOBI file")
        val table = source.read(78, numRecords * 8)
        offsets = LongArray(numRecords) { be32(table, it * 8) }
        for (i in 0 until numRecords) {
            val end = if (i + 1 < numRecords) offsets[i + 1] else source.size
            if (offsets[i] < 78 + numRecords * 8L || offsets[i] > end || end > source.size) {
                throw CorruptBookException("Bad MOBI record table")
            }
        }
        baseHeaders = MobiHeaders(record(0))
        if (baseHeaders.encryption != 0) {
            throw DrmProtectedException(if (baseHeaders.encryption == 1) "Mobipocket (legacy)" else "Mobipocket / Kindle")
        }
        resourceStart = baseHeaders.firstResource
        var h = baseHeaders
        var s = 0
        var kf8 = baseHeaders.version >= 8
        if (!kf8) {
            val boundary = baseHeaders.exthUint(121)
            if (boundary != null && boundary in 1 until numRecords.toLong()) {
                runCatching { MobiHeaders(record(boundary.toInt())) }.getOrNull()?.let {
                    if (it.version >= 8) {
                        h = it
                        s = boundary.toInt()
                        kf8 = true
                    }
                }
            }
        }
        if (h.encryption != 0) throw DrmProtectedException("Mobipocket / Kindle")
        headers = h
        start = s
        isKf8 = kf8
    }

    fun record(i: Int): ByteArray {
        if (i < 0 || i >= numRecords) throw CorruptBookException("Record $i out of range")
        val begin = offsets[i]
        val end = if (i + 1 < numRecords) offsets[i + 1] else source.size
        val length = end - begin
        if (length > 64L shl 20) throw CorruptBookException("Record $i is too large")
        return source.read(begin, length.toInt())
    }

    fun magic(i: Int): String {
        if (i < 0 || i >= numRecords) return ""
        val end = if (i + 1 < numRecords) offsets[i + 1] else source.size
        if (end - offsets[i] < 4) return ""
        return String(source.read(offsets[i], 4), Charsets.ISO_8859_1)
    }

    /** Record relative to the part being read. */
    fun partRecord(i: Long): ByteArray = record((start + i).toInt())

    private val huff: HuffCdic? by lazy {
        if (headers.compression != 17480) {
            null
        } else {
            val first = (start + headers.huffRecord).toInt()
            HuffCdic(record(first), (1 until headers.huffCount.toInt()).map { record(first + it) })
        }
    }

    /** Decompressed text of text record [i] (0-based), trailing entries removed. */
    fun text(i: Int): ByteArray {
        var data = record(start + 1 + i)
        var end = data.size
        val flags = headers.extraDataFlags
        var f = flags ushr 1
        while (f != 0) {
            if (f and 1 != 0) end -= varLenFromEnd(data, end)
            f = f ushr 1
        }
        if (flags and 1 != 0 && end > 0) end -= (data[end - 1].toInt() and 0x3) + 1
        if (end < 0) throw CorruptBookException("Bad trailing entries in text record $i")
        data = data.copyOf(end)
        return when (headers.compression) {
            1 -> data
            2 -> PalmDoc.decompress(data)
            17480 -> huff!!.decompress(data)
            else -> throw CorruptBookException("Unknown MOBI compression ${headers.compression}")
        }
    }

    /** All text of the part, decompressed and concatenated. */
    val fullText: ByteArray by lazy {
        val out = ByteArrayOutputStream()
        for (i in 0 until headers.numTextRecords) {
            out.write(text(i))
            if (out.size() > MAX_TEXT) throw CorruptBookException("Book text is too large")
        }
        out.toByteArray()
    }

    /** Raw bytes of resource number [id] (1-based, as in `recindex` and `kindle:embed`). */
    fun resource(id: Int): ByteArray? {
        if (resourceStart == NULL_INDEX || id < 1) return null
        val index = resourceStart + id - 1
        if (index >= numRecords) return null
        val data = record(index.toInt())
        return when (ascii(data, 0, 4)) {
            "FONT" -> decodeFont(data)
            "VIDE", "AUDI" -> data.copyOfRange(minOf(12, data.size), data.size)
            else -> data
        }
    }

    fun resourceMagic(id: Int): String {
        if (resourceStart == NULL_INDEX || id < 1) return ""
        return magic((resourceStart + id - 1).toInt())
    }

    override fun toString() = "MobiFile(records=$numRecords, kf8=$isKf8, start=$start)"

    companion object {
        private const val MAX_TEXT = 256 shl 20

        /** FONT records: optionally XOR-obfuscated, optionally zlib-compressed. */
        fun decodeFont(record: ByteArray): ByteArray {
            val flags = be32(record, 8)
            val dataStart = be32(record, 12).toInt()
            val keyLength = be32(record, 16).toInt()
            val keyStart = be32(record, 20).toInt()
            if (dataStart !in 0..record.size) throw CorruptBookException("Bad FONT record")
            val data = record.copyOfRange(dataStart, record.size)
            if (flags and 2 != 0L && keyLength > 0 && keyStart + keyLength <= record.size) {
                val key = record.copyOfRange(keyStart, keyStart + keyLength)
                val n = minOf(if (keyLength == 16) 1024 else 1040, data.size)
                for (i in 0 until n) data[i] = (data[i].toInt() xor key[i % key.size].toInt()).toByte()
            }
            if (flags and 1 != 0L) {
                val inflater = Inflater()
                try {
                    inflater.setInput(data)
                    val out = ByteArrayOutputStream(data.size * 2)
                    val buf = ByteArray(16 * 1024)
                    while (!inflater.finished()) {
                        val n = inflater.inflate(buf)
                        if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
                        out.write(buf, 0, n)
                        if (out.size() > 64 shl 20) throw CorruptBookException("Font too large")
                    }
                    return out.toByteArray()
                } catch (e: java.util.zip.DataFormatException) {
                    return data
                } finally {
                    inflater.end()
                }
            }
            return data
        }
    }
}
