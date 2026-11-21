package yokai.pageturn

import eu.kanade.tachiyomi.core.preference.PreferenceStore

/**
 * Page turn animation settings (Bookmania). New keys only: the image reader's existing "animate page
 * transitions" setting (`pref_enable_transitions_key`) keeps its meaning and its default.
 */
class PageTurnPreferences(private val store: PreferenceStore) {

    /** The text reader: [NONE], [SLIDE] or [CURL], for all books. */
    fun textReader() = store.getString(KEY_TEXT_READER, SLIDE)

    /**
     * The image reader's paged modes: taps and keys turn the page with a curl (instead of the existing
     * slide, or no animation). Off by default, so the image reader works as before.
     */
    fun pagerCurl() = store.getBoolean(KEY_PAGER_CURL, false)

    companion object {
        const val KEY_TEXT_READER = "pref_ebook_page_turn"
        const val KEY_PAGER_CURL = "pref_bookmania_pager_curl"

        const val NONE = "none"
        const val SLIDE = "slide"
        const val CURL = "curl"
    }
}
