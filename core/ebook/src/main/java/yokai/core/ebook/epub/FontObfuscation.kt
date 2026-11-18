package yokai.core.ebook.epub

import java.security.MessageDigest

/**
 * EPUB font obfuscation (not DRM): the first bytes of an embedded font are XOR-ed with a key
 * derived from the book's identifier, so that fonts cannot be copied out of the ZIP as-is.
 * Reading systems are expected to undo it (EPUB 3 "Font Obfuscation"; Adobe's older variant).
 */
object FontObfuscation {
    const val IDPF = "http://www.idpf.org/2008/embedding"
    const val ADOBE = "http://ns.adobe.com/pdf/enc#RC"

    fun isObfuscation(algorithm: String) = algorithm == IDPF || algorithm == ADOBE

    /** IDPF: SHA-1 of the unique identifier with all white space removed; first 1040 bytes. */
    fun idpfKey(uniqueIdentifier: String): ByteArray {
        val cleaned = uniqueIdentifier.filterNot { it == ' ' || it == '\t' || it == '\r' || it == '\n' }
        return MessageDigest.getInstance("SHA-1").digest(cleaned.toByteArray(Charsets.UTF_8))
    }

    /** Adobe: the 16 bytes of the book's UUID; first 1024 bytes. Null when no UUID is available. */
    fun adobeKey(identifier: String): ByteArray? {
        val hex = identifier.lowercase().removePrefix("urn:uuid:").filter { it.isDigit() || it in 'a'..'f' }
        if (hex.length != 32) return null
        return ByteArray(16) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    /** Undoes (or applies; XOR is symmetric) the obfuscation in place. */
    fun xor(data: ByteArray, key: ByteArray, count: Int) {
        val n = minOf(count, data.size)
        for (i in 0 until n) data[i] = (data[i].toInt() xor key[i % key.size].toInt()).toByte()
    }

    fun deobfuscate(data: ByteArray, algorithm: String, uniqueIdentifier: String?, uuidIdentifier: String?): ByteArray {
        when (algorithm) {
            IDPF -> uniqueIdentifier?.let { xor(data, idpfKey(it), 1040) }
            ADOBE -> (uuidIdentifier ?: uniqueIdentifier)?.let { adobeKey(it) }?.let { xor(data, it, 1024) }
        }
        return data
    }
}
