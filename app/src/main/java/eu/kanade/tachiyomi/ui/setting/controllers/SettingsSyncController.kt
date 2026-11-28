package eu.kanade.tachiyomi.ui.setting.controllers

import eu.kanade.tachiyomi.ui.setting.SettingsComposeController
import yokai.presentation.settings.ComposableSettings
import yokai.presentation.settings.screen.SettingsSyncScreen

class SettingsSyncController : SettingsComposeController() {
    override fun getComposableSettings(): ComposableSettings = SettingsSyncScreen
}
