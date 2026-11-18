package yokai.core.ebook.io

import java.io.Closeable
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * Random access to the bytes of a book file.
 *
 * Positional reads must be safe to call from several threads at once: the reader's
 * WebView asks for resources on a pool of background threads.
 */
interface RandomAccessSource : Closeable {
    val size: Long

    /** Reads exactly [length] bytes starting at [position] into [buffer] at [offset]. */
    fun readFully(position: Long, buffer: ByteArray, offset: Int = 0, length: Int = buffer.size - offset)

    fun read(position: Long, length: Int): ByteArray = ByteArray(length).also { readFully(position, it, 0, length) }

    /** A stream over [length] bytes starting at [position]. */
    fun stream(position: Long, length: Long): InputStream = SourceInputStream(this, position, length)
}

/** [FileChannel] positional reads do not touch the channel position, so they can run concurrently. */
class FileChannelSource(
    private val channel: FileChannel,
    private val onClose: () -> Unit = { channel.close() },
) : RandomAccessSource {
    override val size: Long = channel.size()

    override fun readFully(position: Long, buffer: ByteArray, offset: Int, length: Int) {
        checkRange(position, length, size)
        val bb = ByteBuffer.wrap(buffer, offset, length)
        var pos = position
        while (bb.hasRemaining()) {
            val n = channel.read(bb, pos)
            if (n < 0) throw EOFException("Unexpected end of file at $pos")
            pos += n
        }
    }

    override fun close() = onClose()

    companion object {
        fun open(file: File): FileChannelSource {
            val raf = RandomAccessFile(file, "r")
            return FileChannelSource(raf.channel) { raf.close() }
        }
    }
}

class ByteArraySource(private val data: ByteArray) : RandomAccessSource {
    override val size: Long get() = data.size.toLong()

    override fun readFully(position: Long, buffer: ByteArray, offset: Int, length: Int) {
        checkRange(position, length, size)
        System.arraycopy(data, position.toInt(), buffer, offset, length)
    }

    override fun close() = Unit
}

internal fun checkRange(position: Long, length: Int, size: Long) {
    if (position < 0 || length < 0 || position > size - length) {
        throw EOFException("Read of $length bytes at $position is outside a file of $size bytes")
    }
}

internal class SourceInputStream(
    private val source: RandomAccessSource,
    start: Long,
    length: Long,
) : InputStream() {
    private var pos = start
    private val end = start + length
    private var mark = start

    init {
        if (start < 0 || length < 0 || end > source.size) throw EOFException("Stream range outside the file")
    }

    override fun read(): Int {
        if (pos >= end) return -1
        val b = ByteArray(1)
        source.readFully(pos++, b, 0, 1)
        return b[0].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (pos >= end) return -1
        val n = minOf(len.toLong(), end - pos).toInt()
        source.readFully(pos, b, off, n)
        pos += n
        return n
    }

    override fun skip(n: Long): Long {
        val k = minOf(maxOf(n, 0), end - pos)
        pos += k
        return k
    }

    override fun available(): Int = minOf(end - pos, Int.MAX_VALUE.toLong()).toInt()
    override fun markSupported() = true
    override fun mark(readlimit: Int) { mark = pos }
    override fun reset() { pos = mark }
}
