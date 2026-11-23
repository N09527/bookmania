package yokai.gutter

import eu.kanade.tachiyomi.core.preference.PreferenceStore

/**
 * Gutter shadow settings (Bookmania, stage 7): a shadow in the fold between two facing pages. New keys only;
 * on unless turned off (decided by the user). One setting for all books in each reader.
 */
class GutterPreferences(private val store: PreferenceStore) {

    /** The text reader, with two columns. */
    fun textReader() = store.getBoolean(KEY_TEXT_READER, true)

    /** The image reader's paged modes, where two pages are shown merged (double pages). */
    fun pager() = store.getBoolean(KEY_PAGER, true)

    companion object {
        const val KEY_TEXT_READER = "pref_ebook_gutter_shadow"
        const val KEY_PAGER = "pref_bookmania_pager_gutter_shadow"
    }
}
