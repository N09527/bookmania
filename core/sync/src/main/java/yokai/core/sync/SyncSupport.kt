package yokai.core.sync

import java.security.MessageDigest
import java.util.UUID

/** Identifiers of sync-format.md section 2. */
object SyncIds {
    /** Android's LocalSource.ID. */
    const val LOCAL_SOURCE = 0L

    fun workKey(source: Long, url: String) = "$source:$url"

    fun localWorkKey(folder: String) = workKey(LOCAL_SOURCE, folder)

    /** The local source's work folder of a work key, or null for another source. */
    fun localFolder(workKey: String) = if (workKey.startsWith("$LOCAL_SOURCE:")) workKey.substringAfter(':') else null

    /** The progress file of a work: the SHA-1 of the work key's UTF-8 bytes, in lower-case hex. */
    fun progressFileName(workKey: String): String {
        val digest = MessageDigest.getInstance("SHA-1").digest(workKey.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it.toInt() and 0xFF) } + ".json"
    }

    fun newDeviceId(): String = UUID.randomUUID().toString().lowercase()
}

/** The checks on file names from the server before anything is written locally (sync-format.md section 5.3). */
object SyncNames {
    fun validSegment(segment: String): Boolean =
        segment.isNotEmpty() &&
            segment != "." && segment != ".." && !segment.startsWith(".") &&
            segment.none { it == '/' || it == '\\' || it.isISOControl() } &&
            segment.toByteArray(Charsets.UTF_8).size <= 255

    fun validPath(path: String): Boolean {
        val parts = path.split('/')
        return parts.size in 1..2 && parts.all(::validSegment)
    }

    fun valid(item: FileItem) = validSegment(item.work) && validPath(item.path)
}
