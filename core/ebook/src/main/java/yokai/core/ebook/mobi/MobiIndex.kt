package yokai.core.ebook.mobi

// Kotlin port of parts of foliate-js mobi.js (MIT License, Copyright (c) 2022 John Factotum);
// see core/ebook/NOTICE-foliate-js.txt.

import java.nio.charset.Charset
import yokai.core.ebook.CorruptBookException

/** One entry of an INDX table: its name and tag values. */
internal data class IndexEntry(val name: String, val tags: Map<Int, List<Long>>) {
    fun tag(tag: Int, i: Int = 0): Long? = tags[tag]?.getOrNull(i)
}

internal class IndexData(val entries: List<IndexEntry>, val cncx: Map<Int, String>)

/** Reads an INDX index (header record, entry records, CNCX string records). */
internal object MobiIndex {

    fun read(firstRecord: Int, loadRecord: (Int) -> ByteArray, fallbackCharset: Charset): IndexData {
        val header = loadRecord(firstRecord)
        if (ascii(header, 0, 4) != "INDX") throw CorruptBookException("Invalid INDX record")
        val headerLength = be32(header, 4).toInt()
        val numRecords = be32(header, 24).toInt()
        val encoding = be32(header, 28)
        val numCncx = be32(header, 52).toInt()
        val charset = when (encoding) {
            65001L -> Charsets.UTF_8
            1252L -> Charset.forName("windows-1252")
            else -> fallbackCharset
        }
        if (numRecords < 0 || numRecords > 10_000 || numCncx < 0 || numCncx > 10_000) {
            throw CorruptBookException("Unreasonable INDX size")
        }

        // TAGX: the tag table describing how entries are encoded.
        if (ascii(header, headerLength, 4) != "TAGX") throw CorruptBookException("Invalid TAGX section")
        val tagxLength = be32(header, headerLength + 4).toInt()
        val numControlBytes = be32(header, headerLength + 8).toInt()
        val numTags = (tagxLength - 12) / 4
        val tagTable = (0 until numTags).map { i ->
            val p = headerLength + 12 + i * 4
            IntArray(4) { k -> header[p + k].toInt() and 0xFF } // tag, values per entry, mask, end flag
        }

        // CNCX: strings referenced by offset (records come right after the entry records).
        val cncx = HashMap<Int, String>()
        var recordOffset = 0
        for (i in 0 until numCncx) {
            val record = loadRecord(firstRecord + numRecords + i + 1)
            var pos = 0
            while (pos < record.size) {
                val index = pos
                val (len, lenBytes) = varLen(record, pos)
                if (lenBytes == 0) break
                pos += lenBytes
                val end = minOf(record.size, pos + len.toInt())
                cncx[recordOffset + index] = String(record, pos, end - pos, charset)
                pos = end
            }
            recordOffset += 0x10000
        }

        val entries = ArrayList<IndexEntry>()
        for (r in 0 until numRecords) {
            val record = loadRecord(firstRecord + 1 + r)
            if (ascii(record, 0, 4) != "INDX") throw CorruptBookException("Invalid INDX entry record")
            val idxt = be32(record, 20).toInt()
            val count = be32(record, 24).toInt()
            for (j in 0 until count) {
                val offset = be16(record, idxt + 4 + 2 * j)
                val nameLength = record[offset].toInt() and 0xFF
                val name = String(record, offset + 1, nameLength, Charsets.ISO_8859_1)
                entries.add(IndexEntry(name, readTags(record, offset + 1 + nameLength, numControlBytes, tagTable)))
            }
        }
        return IndexData(entries, cncx)
    }

    private fun readTags(record: ByteArray, startPos: Int, numControlBytes: Int, tagTable: List<IntArray>): Map<Int, List<Long>> {
        data class Pending(val tag: Int, val valueCount: Int?, val valueBytes: Long?, val valuesPerEntry: Int)

        var controlByteIndex = 0
        var pos = startPos + numControlBytes
        val pending = ArrayList<Pending>()
        for (t in tagTable) {
            val (tag, valuesPerEntry, mask, end) = listOf(t[0], t[1], t[2], t[3])
            if (end and 1 != 0) {
                controlByteIndex++
                continue
            }
            val value = (record[startPos + controlByteIndex].toInt() and 0xFF) and mask
            if (value == mask) {
                if (countBitsSet(mask) > 1) {
                    val (v, len) = varLen(record, pos)
                    pending.add(Pending(tag, null, v, valuesPerEntry))
                    pos += len
                } else {
                    pending.add(Pending(tag, 1, null, valuesPerEntry))
                }
            } else {
                pending.add(Pending(tag, value shr countUnsetEnd(mask), null, valuesPerEntry))
            }
        }
        val tags = HashMap<Int, List<Long>>()
        for (p in pending) {
            val values = ArrayList<Long>()
            if (p.valueCount != null) {
                repeat(p.valueCount * p.valuesPerEntry) {
                    val (v, len) = varLen(record, pos)
                    values.add(v)
                    pos += len
                }
            } else {
                var consumed = 0L
                while (consumed < (p.valueBytes ?: 0)) {
                    val (v, len) = varLen(record, pos)
                    if (len == 0) break
                    values.add(v)
                    pos += len
                    consumed += len
                }
            }
            tags[p.tag] = values
        }
        return tags
    }
}
