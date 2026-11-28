package yokai.sync

import yokai.ebook.settings.EbookSettings
import yokai.ebook.settings.EbookSettingsStore

/**
 * The settings the WebDAV sync carries, with the type each is stored with (design.md 3.7): the typesetting
 * settings of the three levels, the readers' and the library's settings. The iOS version syncs the same keys
 * (BackupMapper.preferenceType in BookmaniaCore, without incognito mode). Incognito mode is left out: it is a
 * choice for one device.
 */
object SyncSettingsKeys {
    private val typed: Map<String, String> = buildMap {
        for (key in EbookSettings.Key.entries) put(EbookSettingsStore.globalKey(key), "string")
        put("pref_ebook_page_turn", "string")
        put("pref_ebook_gutter_shadow", "bool")
        put("pref_bookmania_pager_curl", "bool")
        put("pref_bookmania_pager_gutter_shadow", "bool")
        put("pref_reader_theme_key", "int")
        put("reader_navigation_mode_pager", "int")
        put("reader_tapping_inverted", "string")
        put("pref_keep_screen_on_key", "bool")
        put("pref_default_reading_mode_key", "int")
        put("page_layout", "int")
        put("invert_double_pages", "bool")
        put("library_sorting_mode", "int")
        put("library_sorting_ascending", "bool")
        put("pref_filter_unread_key", "int")
        put("pref_filter_completed_key", "int")
        put("pref_filter_bookmarked_key", "int")
        put("pref_display_library_layout", "int")
        put("unread_badge_type", "int")
    }

    private const val OVERRIDE_PREFIX = "pref_ebook_override_"

    /** "string", "int" or "bool" for a synced key, or null. */
    fun type(key: String): String? = typed[key] ?: if (key.startsWith(OVERRIDE_PREFIX)) "string" else null
}
