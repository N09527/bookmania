package yokai.core.ebook.io

import java.io.Closeable
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.charset.Charset
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream
import yokai.core.ebook.CorruptBookException
import yokai.core.ebook.UnreadableFileException

/**
 * Minimal ZIP reader working on a [RandomAccessSource] (no temporary copies, works with any
 * seekable file descriptor). Reads the central directory once; entries are opened on demand.
 * Supports STORED and DEFLATED entries and ZIP64. Decompressed sizes are capped to defend
 * against decompression bombs.
 */
class ZipReader(
    private val source: RandomAccessSource,
    private val limits: Limits = Limits(),
) : Closeable {

    data class Entry(
        val name: String,
        val method: Int,
        val flags: Int,
        val compressedSize: Long,
        val size: Long,
        val localHeaderOffset: Long,
    ) {
        val isDirectory: Boolean get() = name.endsWith("/")
        val isEncrypted: Boolean get() = flags and 1 != 0
    }

    data class Limits(
        val maxEntries: Int = 50_000,
        val maxEntrySize: Long = 512L shl 20,
        val maxCompressionRatio: Long = 2_000,
    )

    /** Entries in central-directory order, keyed by their exact name. */
    val entries: Map<String, Entry>

    private val lowerCaseIndex: Map<String, String>

    init {
        entries = try {
            readCentralDirectory()
        } catch (e: CorruptBookException) {
            throw e
        } catch (e: Exception) {
            throw UnreadableFileException("Cannot read the ZIP directory", e)
        }
        lowerCaseIndex = entries.keys.associateBy { it.lowercase() }
    }

    fun has(name: String) = find(name) != null

    /** Exact match first, then a case-insensitive match (some books get the case of links wrong). */
    fun find(name: String): Entry? = entries[name] ?: lowerCaseIndex[name.lowercase()]?.let { entries[it] }

    fun open(name: String): InputStream? {
        val e = find(name) ?: return null
        return open(e)
    }

    fun open(e: Entry): InputStream {
        if (e.isEncrypted) throw CorruptBookException("Encrypted ZIP entry: ${e.name}")
        if (e.size > limits.maxEntrySize) throw CorruptBookException("Entry too large: ${e.name}")
        val header = source.read(e.localHeaderOffset, 30)
        if (le32(header, 0) != LOCAL_SIG) throw CorruptBookException("Bad local header for ${e.name}")
        val dataStart = e.localHeaderOffset + 30 + le16(header, 26) + le16(header, 28)
        val raw = source.stream(dataStart, e.compressedSize)
        val cap = minOf(e.size, limits.maxEntrySize)
        return when (e.method) {
            0 -> raw
            8 -> {
                if (e.compressedSize > 0 && e.size / e.compressedSize > limits.maxCompressionRatio) {
                    throw CorruptBookException("Suspicious compression ratio: ${e.name}")
                }
                LimitedInputStream(InflaterInputStream(raw, Inflater(true), 16 * 1024), cap, e.name)
            }
            else -> throw CorruptBookException("Unsupported compression method ${e.method}: ${e.name}")
        }
    }

    fun readBytes(name: String): ByteArray? = open(name)?.use { it.readBytes() }

    fun readText(name: String, charset: Charset = Charsets.UTF_8): String? = readBytes(name)?.toString(charset)

    override fun close() = source.close()

    private fun readCentralDirectory(): Map<String, Entry> {
        val size = source.size
        if (size < 22) throw UnreadableFileException("File too small to be a ZIP archive")
        val tailLen = minOf(size, 22L + 0xFFFF).toInt()
        val tailStart = size - tailLen
        val tail = source.read(tailStart, tailLen)
        var eocd = -1
        for (i in tailLen - 22 downTo 0) {
            if (le32(tail, i) == EOCD_SIG) { eocd = i; break }
        }
        if (eocd < 0) throw UnreadableFileException("ZIP end-of-directory record not found (file truncated?)")
        var total = le16(tail, eocd + 10).toLong()
        var cdSize = le32(tail, eocd + 12)
        var cdOffset = le32(tail, eocd + 16)
        if (total == 0xFFFFL || cdSize == 0xFFFFFFFFL || cdOffset == 0xFFFFFFFFL) {
            // ZIP64: the locator sits right before the classic record.
            val locAt = tailStart + eocd - 20
            if (locAt >= 0) {
                val loc = source.read(locAt, 20)
                if (le32(loc, 0) == ZIP64_LOCATOR_SIG) {
                    val z64At = le64(loc, 8)
                    val z64 = source.read(z64At, 56)
                    if (le32(z64, 0) != ZIP64_EOCD_SIG) throw CorruptBookException("Bad ZIP64 directory record")
                    total = le64(z64, 32)
                    cdSize = le64(z64, 40)
                    cdOffset = le64(z64, 48)
                }
            }
        }
        if (total > limits.maxEntries) throw CorruptBookException("Too many ZIP entries: $total")
        if (cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > size) throw CorruptBookException("ZIP directory outside the file")
        val cd = source.read(cdOffset, cdSize.toInt())
        val out = LinkedHashMap<String, Entry>()
        var p = 0
        for (n in 0 until total) {
            if (p + 46 > cd.size || le32(cd, p) != CENTRAL_SIG) throw CorruptBookException("Bad ZIP directory entry #$n")
            val flags = le16(cd, p + 8)
            val method = le16(cd, p + 10)
            var csize = le32(cd, p + 20)
            var usize = le32(cd, p + 24)
            val nameLen = le16(cd, p + 28)
            val extraLen = le16(cd, p + 30)
            val commentLen = le16(cd, p + 32)
            var lho = le32(cd, p + 42)
            val nameBytes = cd.copyOfRange(p + 46, p + 46 + nameLen)
            val name = String(nameBytes, if (flags and 0x800 != 0) Charsets.UTF_8 else guessNameCharset(nameBytes))
            // ZIP64 extra field (0x0001): only the fields that overflowed are present, in order.
            var e = p + 46 + nameLen
            val extraEnd = e + extraLen
            while (e + 4 <= extraEnd) {
                val id = le16(cd, e)
                val len = le16(cd, e + 2)
                if (id == 0x0001) {
                    var q = e + 4
                    if (usize == 0xFFFFFFFFL) { usize = le64(cd, q); q += 8 }
                    if (csize == 0xFFFFFFFFL) { csize = le64(cd, q); q += 8 }
                    if (lho == 0xFFFFFFFFL) { lho = le64(cd, q) }
                }
                e += 4 + len
            }
            if (lho < 0 || lho >= size) throw CorruptBookException("ZIP entry outside the file: $name")
            out[name] = Entry(name, method, flags, csize, usize, lho)
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    private class LimitedInputStream(input: InputStream, private val cap: Long, private val name: String) : FilterInputStream(input) {
        private var count = 0L
        override fun read(): Int {
            val b = super.read()
            if (b >= 0 && ++count > cap) throw IOException("Entry larger than declared: $name")
            return b
        }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val n = super.read(b, off, len)
            if (n > 0) {
                count += n
                if (count > cap) throw IOException("Entry larger than declared: $name")
            }
            return n
        }
    }

    companion object {
        private const val LOCAL_SIG = 0x04034b50L
        private const val CENTRAL_SIG = 0x02014b50L
        private const val EOCD_SIG = 0x06054b50L
        private const val ZIP64_EOCD_SIG = 0x06064b50L
        private const val ZIP64_LOCATOR_SIG = 0x07064b50L

        internal fun le16(b: ByteArray, i: Int): Int = (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8)
        internal fun le32(b: ByteArray, i: Int): Long = (le16(b, i).toLong()) or (le16(b, i + 2).toLong() shl 16)
        internal fun le64(b: ByteArray, i: Int): Long = le32(b, i) or (le32(b, i + 4) shl 32)

        /** Names without the UTF-8 flag are usually UTF-8 anyway in e-books; fall back to CP437 otherwise. */
        private fun guessNameCharset(bytes: ByteArray): Charset {
            val decoder = Charsets.UTF_8.newDecoder()
            return try {
                decoder.decode(java.nio.ByteBuffer.wrap(bytes))
                Charsets.UTF_8
            } catch (_: java.nio.charset.CharacterCodingException) {
                runCatching { Charset.forName("IBM437") }.getOrDefault(Charsets.ISO_8859_1)
            }
        }
    }
}
