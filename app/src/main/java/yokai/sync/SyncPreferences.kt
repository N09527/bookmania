package yokai.sync

import eu.kanade.tachiyomi.core.preference.Preference
import eu.kanade.tachiyomi.core.preference.PreferenceStore

/**
 * The WebDAV sync's settings (docs/extensions-and-sync/design.md). All are private keys: backups leave them out,
 * and the sync does not send them (the account and the device id belong to this device).
 */
class SyncPreferences(private val store: PreferenceStore) {
    fun enabled() = store.getBoolean(Preference.privateKey("bookmania_sync_enabled"), false)

    /** The WebDAV address; only https is accepted. */
    fun serverUrl() = store.getString(Preference.privateKey("bookmania_sync_url"), "")

    fun user() = store.getString(Preference.privateKey("bookmania_sync_user"), "")

    /** The password, encrypted with a key of the Android keystore ([SyncSecrets]). */
    fun passwordCipher() = store.getString(Preference.privateKey("bookmania_sync_password"), "")

    fun syncFiles() = store.getBoolean(Preference.privateKey("bookmania_sync_files"), true)

    /** Book files move only on networks that are not metered (Wi-Fi). */
    fun filesUnmeteredOnly() = store.getBoolean(Preference.privateKey("bookmania_sync_files_unmetered"), true)

    fun deviceId() = store.getString(Preference.privateKey("bookmania_sync_device_id"), "")

    fun lastSync() = store.getLong(Preference.privateKey("bookmania_sync_last"), 0)

    /** The outcome of the last sync, for the settings screen (empty when it went well). */
    fun lastError() = store.getString(Preference.privateKey("bookmania_sync_last_error"), "")

    /** Book files with the same name but another size here and on the server (the last file sync). */
    fun lastConflicts() = store.getStringSet(Preference.privateKey("bookmania_sync_conflicts"), emptySet())

    /** Book files the last file sync could not move or would not take (bad names), with the reasons. */
    fun lastFileProblems() = store.getStringSet(Preference.privateKey("bookmania_sync_file_problems"), emptySet())
}
