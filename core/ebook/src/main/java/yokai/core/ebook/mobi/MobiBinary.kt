package yokai.core.ebook.mobi

import java.io.ByteArrayOutputStream
import yokai.core.ebook.CorruptBookException

// Format knowledge: MobileRead wiki ("MOBI", "PalmDOC", "KF8") and foliate-js `mobi.js`
// (MIT License, Copyright (c) 2022 John Factotum), which this implementation follows;
// see core/ebook/NOTICE-foliate-js.txt.

internal fun be16(b: ByteArray, i: Int): Int {
    if (i < 0 || i + 2 > b.size) throw CorruptBookException("Read outside a record")
    return ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
}

internal fun be32(b: ByteArray, i: Int): Long {
    if (i < 0 || i + 4 > b.size) throw CorruptBookException("Read outside a record")
    return ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
        ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)
}

internal fun be32or(b: ByteArray, i: Int, default: Long): Long = if (i >= 0 && i + 4 <= b.size) be32(b, i) else default

internal fun ascii(b: ByteArray, i: Int, n: Int): String =
    if (i < 0 || i + n > b.size) "" else String(b, i, n, Charsets.ISO_8859_1)

internal const val NULL_INDEX = 0xFFFFFFFFL

/** Forward variable-length integer used in INDX records: the high bit marks the last byte. */
internal fun varLen(b: ByteArray, start: Int): Pair<Long, Int> {
    var value = 0L
    var length = 0
    var i = start
    while (i < b.size && length < 4) {
        val byte = b[i].toInt() and 0xFF
        value = (value shl 7) or (byte and 0x7F).toLong()
        length++
        i++
        if (byte and 0x80 != 0) break
    }
    return value to length
}

/** Variable-length integer stored backwards at the end of a text record (trailing entries). */
internal fun varLenFromEnd(b: ByteArray, end: Int): Int {
    var value = 0
    for (i in maxOf(0, end - 4) until end) {
        val byte = b[i].toInt() and 0xFF
        if (byte and 0x80 != 0) value = 0
        value = (value shl 7) or (byte and 0x7F)
    }
    return value
}

internal fun countBitsSet(x: Int): Int = Integer.bitCount(x)

internal fun countUnsetEnd(x: Int): Int {
    if (x == 0) return 0
    return Integer.numberOfTrailingZeros(x)
}

/** PalmDOC LZ77 decompression. */
internal object PalmDoc {
    fun decompress(input: ByteArray, maxOutput: Int = 1 shl 20): ByteArray {
        val out = GrowableBytes(input.size * 2)
        var i = 0
        while (i < input.size) {
            val byte = input[i].toInt() and 0xFF
            when {
                byte == 0 -> out.add(0)
                byte <= 8 -> {
                    // copy the next 1-8 bytes literally
                    val end = minOf(i + 1 + byte, input.size)
                    for (j in i + 1 until end) out.add(input[j].toInt() and 0xFF)
                    i += byte
                }
                byte <= 0x7F -> out.add(byte)
                byte <= 0xBF -> {
                    // length-distance pair
                    if (i + 1 >= input.size) break
                    val pair = (byte shl 8) or (input[++i].toInt() and 0xFF)
                    val distance = (pair and 0x3FFF) ushr 3
                    val length = (pair and 0x7) + 3
                    if (distance == 0 || distance > out.size) throw CorruptBookException("Bad PalmDOC back-reference")
                    for (k in 0 until length) out.add(out.get(out.size - distance))
                }
                else -> {
                    // space + character
                    out.add(0x20)
                    out.add(byte xor 0x80)
                }
            }
            if (out.size > maxOutput) throw CorruptBookException("PalmDOC record decompresses beyond its limit")
            i++
        }
        return out.toByteArray()
    }
}

internal class GrowableBytes(initial: Int = 4096) {
    private var buf = ByteArray(maxOf(16, initial))
    var size = 0
        private set

    fun add(b: Int) {
        if (size == buf.size) buf = buf.copyOf(buf.size * 2)
        buf[size++] = b.toByte()
    }

    fun addAll(src: ByteArray) {
        if (size + src.size > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, size + src.size))
        System.arraycopy(src, 0, buf, size, src.size)
        size += src.size
    }

    fun get(i: Int): Int = buf[i].toInt() and 0xFF

    fun toByteArray(): ByteArray = buf.copyOf(size)
}

/** HUFF/CDIC ("huffdic") decompression used by many Kindle books. */
internal class HuffCdic(huffRecord: ByteArray, cdicRecords: List<ByteArray>) {
    private val table1 = IntArray(256)
    private val minCode = LongArray(33)
    private val maxCode = LongArray(33)
    private val dictionary = ArrayList<ByteArray>()
    private val resolved = ArrayList<Boolean>()

    init {
        if (ascii(huffRecord, 0, 4) != "HUFF") throw CorruptBookException("Invalid HUFF record")
        val offset1 = be32(huffRecord, 8).toInt()
        val offset2 = be32(huffRecord, 12).toInt()
        for (i in 0 until 256) table1[i] = be32(huffRecord, offset1 + i * 4).toInt()
        for (len in 1..32) {
            minCode[len] = be32(huffRecord, offset2 + (len - 1) * 8)
            maxCode[len] = be32(huffRecord, offset2 + (len - 1) * 8 + 4)
        }
        var total = -1L
        for (record in cdicRecords) {
            if (ascii(record, 0, 4) != "CDIC") throw CorruptBookException("Invalid CDIC record")
            val headerLength = be32(record, 4).toInt()
            if (total < 0) total = be32(record, 8)
            val codeLength = be32(record, 12).toInt()
            val n = minOf(1L shl codeLength, total - dictionary.size).toInt()
            for (i in 0 until n) {
                val offset = be16(record, headerLength + i * 2)
                val x = be16(record, headerLength + offset)
                val length = x and 0x7FFF
                val start = headerLength + offset + 2
                if (start + length > record.size) throw CorruptBookException("CDIC entry outside its record")
                dictionary.add(record.copyOfRange(start, start + length))
                resolved.add(x and 0x8000 != 0)
            }
        }
    }

    fun decompress(input: ByteArray, depth: Int = 0): ByteArray {
        if (depth > 32) throw CorruptBookException("HUFF/CDIC recursion too deep")
        val out = GrowableBytes(input.size * 3)
        val bitLength = input.size.toLong() * 8
        var pos = 0L
        while (pos < bitLength) {
            val bits = read32(input, pos)
            val entry = table1[(bits ushr 24).toInt()]
            var codeLength = entry and 0x1F
            var value = (entry.toLong() and 0xFFFFFFFFL) ushr 8
            if (entry and 0x80 == 0) {
                while (codeLength < 32 && (bits ushr (32 - codeLength)) < minCode[codeLength]) codeLength++
                value = maxCode[codeLength]
            }
            if (codeLength == 0) throw CorruptBookException("Bad HUFF code")
            pos += codeLength
            if (pos > bitLength) break
            val code = (value - (bits ushr (32 - codeLength))).toInt()
            if (code < 0 || code >= dictionary.size) throw CorruptBookException("HUFF code outside the dictionary")
            if (!resolved[code]) {
                dictionary[code] = decompress(dictionary[code], depth + 1)
                resolved[code] = true
            }
            out.addAll(dictionary[code])
        }
        return out.toByteArray()
    }

    /** 32 bits starting at bit [from] (big-endian), zero-padded past the end. */
    private fun read32(b: ByteArray, from: Long): Long {
        val startByte = (from ushr 3).toInt()
        val shift = (from and 7).toInt()
        var v = 0L
        for (k in 0 until 5) {
            val idx = startByte + k
            v = (v shl 8) or (if (idx < b.size) (b[idx].toLong() and 0xFF) else 0L)
        }
        return (v ushr (8 - shift)) and 0xFFFFFFFFL
    }
}

/** Collects bytes for building documents. */
internal fun ByteArrayOutputStream.write(s: String) = write(s.toByteArray(Charsets.UTF_8))
