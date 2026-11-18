package yokai.core.ebook

/** Base class for problems with a book file that the reader should explain to the user. */
open class BookException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** The book uses DRM. It is never decrypted; the reader only explains that it cannot be opened. */
class DrmProtectedException(val scheme: String) : BookException("The book is protected by DRM ($scheme)")

/** The file is damaged or is not what its extension says. */
class CorruptBookException(message: String, cause: Throwable? = null) : BookException(message, cause)

/** A known format that this reader does not handle (for example KFX). */
class UnsupportedBookException(message: String) : BookException(message)
