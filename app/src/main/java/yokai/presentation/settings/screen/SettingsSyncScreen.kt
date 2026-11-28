package yokai.presentation.settings.screen

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.stringResource
import eu.kanade.tachiyomi.core.storage.preference.collectAsState
import eu.kanade.tachiyomi.util.compose.LocalDialogHostState
import eu.kanade.tachiyomi.util.compose.currentOrThrow
import eu.kanade.tachiyomi.util.relativeTimeSpanString
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.launch
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import yokai.domain.DialogHostState
import yokai.i18n.MR
import yokai.presentation.component.preference.Preference
import yokai.presentation.settings.ComposableSettings
import yokai.sync.SyncManager
import yokai.sync.SyncPreferences
import yokai.sync.SyncSecrets
import yokai.sync.SyncWorker

/** The WebDAV sync (docs/extensions-and-sync): the server, whether to sync and the book files, the last outcome. */
object SettingsSyncScreen : ComposableSettings() {

    private fun readResolve(): Any = SettingsSyncScreen

    @Composable
    override fun getTitleRes(): StringResource = MR.strings.sync_title

    @Composable
    override fun getPreferences(): List<Preference> {
        val prefs = remember { Injekt.get<SyncPreferences>() }
        val manager = remember { Injekt.get<SyncManager>() }
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val dialogs = LocalDialogHostState.currentOrThrow
        val url by prefs.serverUrl().collectAsState()
        val user by prefs.user().collectAsState()
        val enabled by prefs.enabled().collectAsState()
        val last by prefs.lastSync().collectAsState()
        val error by prefs.lastError().collectAsState()
        val conflicts by prefs.lastConflicts().collectAsState()

        val status = buildList {
            if (error.isNotBlank()) {
                add(stringResource(MR.strings.sync_last_error, error))
            } else {
                add(stringResource(MR.strings.sync_last, relativeTimeSpanString(last)))
            }
            if (conflicts.isNotEmpty()) add(stringResource(MR.strings.sync_conflicts, conflicts.sorted().joinToString("、")))
        }.joinToString("\n")

        return persistentListOf(
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.sync_server),
                subtitle = if (url.isBlank()) stringResource(MR.strings.sync_server_not_set) else "$user · $url",
                onClick = { scope.launch { dialogs.awaitSyncAccount(context, prefs, manager) } },
            ),
            Preference.PreferenceItem.SwitchPreference(
                pref = prefs.enabled(),
                title = stringResource(MR.strings.sync_enable),
                enabled = url.isNotBlank(),
                onValueChanged = { on ->
                    // The job checks the setting when it runs, after this change is saved.
                    if (on) SyncWorker.library(context)
                    true
                },
            ),
            Preference.PreferenceItem.SwitchPreference(
                pref = prefs.syncFiles(),
                title = stringResource(MR.strings.sync_files),
                subtitle = stringResource(MR.strings.sync_files_summary),
            ),
            Preference.PreferenceItem.SwitchPreference(
                pref = prefs.filesUnmeteredOnly(),
                title = stringResource(MR.strings.sync_files_unmetered),
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.sync_now),
                subtitle = status,
                enabled = enabled && url.isNotBlank(),
                onClick = {
                    context.toast(MR.strings.sync_started)
                    SyncWorker.library(context)
                },
            ),
            Preference.PreferenceItem.InfoPreference(stringResource(MR.strings.sync_info)),
        )
    }
}

/** The server's address, account and password; the password is kept encrypted ([SyncSecrets]). */
private suspend fun DialogHostState.awaitSyncAccount(context: Context, prefs: SyncPreferences, manager: SyncManager): Unit =
    dialog { cont ->
        var url by remember { mutableStateOf(prefs.serverUrl().get()) }
        var user by remember { mutableStateOf(prefs.user().get()) }
        var password by remember { mutableStateOf(SyncSecrets.decrypt(prefs.passwordCipher().get()) ?: "") }
        var message by remember { mutableStateOf<String?>(null) }
        var busy by remember { mutableStateOf(false) }
        val scope = rememberCoroutineScope()
        val httpsOnly = stringResource(MR.strings.sync_https_only)
        val testing = stringResource(MR.strings.sync_testing)
        val ok = stringResource(MR.strings.sync_test_ok)
        val failed = stringResource(MR.strings.sync_test_failed)
        fun valid() = url.trim().startsWith("https://", ignoreCase = true)

        AlertDialog(
            onDismissRequest = { if (!busy) cont.cancel() },
            title = { Text(stringResource(MR.strings.sync_account_title)) },
            text = {
                Column {
                    OutlinedTextField(
                        value = url,
                        onValueChange = { url = it },
                        label = { Text(stringResource(MR.strings.sync_url)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    )
                    OutlinedTextField(
                        value = user,
                        onValueChange = { user = it },
                        label = { Text(stringResource(MR.strings.sync_user)) },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text(stringResource(MR.strings.sync_password)) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(stringResource(MR.strings.sync_account_changed), style = MaterialTheme.typography.bodySmall)
                    message?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        if (!valid()) {
                            message = httpsOnly
                            return@TextButton
                        }
                        val newUrl = url.trim()
                        if (newUrl != prefs.serverUrl().get() || user != prefs.user().get()) manager.reset()
                        prefs.serverUrl().set(newUrl)
                        prefs.user().set(user)
                        prefs.passwordCipher().set(SyncSecrets.encrypt(password))
                        if (prefs.enabled().get()) SyncWorker.library(context)
                        cont.cancel()
                    },
                ) { Text(stringResource(MR.strings.sync_save)) }
            },
            dismissButton = {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        if (!valid()) {
                            message = httpsOnly
                            return@TextButton
                        }
                        busy = true
                        message = testing
                        scope.launch {
                            val problem = manager.test(url.trim(), user, password)
                            message = if (problem == null) ok else failed.replace("%s", problem)
                            busy = false
                        }
                    },
                ) { Text(stringResource(MR.strings.sync_test)) }
            },
        )
    }
