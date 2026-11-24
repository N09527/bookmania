package yokai.ebook.settings

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBarsIgnoringVisibility
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.AbsoluteRoundedCornerShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.AbsoluteAlignment
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.stringResource
import kotlin.math.abs
import kotlin.math.roundToInt
import yokai.ebook.settings.EbookSettings.Companion.Range
import yokai.ebook.settings.EbookSettings.Key
import yokai.i18n.MR
import yokai.pageturn.PageTurnPreferences

/** What the settings panel shows. */
data class EbookSettingsUiState(
    /** The settings as seen from [scope] (that level and the ones above it). */
    val settings: EbookSettings,
    val scope: SettingsScope,
    /** Whether [scope] sets anything itself (otherwise there is nothing to clear). */
    val scopeHasValues: Boolean,
    /** Keys a nearer level sets for this book; on the page those values are used. */
    val overridden: Map<Key, SettingsScope>,
    val fonts: List<ImportedFont>,
    /** The page turn animation ([PageTurnPreferences.textReader]): one setting for all books. */
    val pageTurn: String,
    /** The fold's shadow with two columns ([yokai.gutter.GutterPreferences.textReader]): one setting for all books. */
    val gutterShadow: Boolean,
    /**
     * When the settings ask for two columns on this screen: the largest left + right margins that keep two columns
     * of at least 120 dp (from the shell, stage 8). The left and right margin sliders and fields stop there.
     */
    val marginMost: Int? = null,
)

/**
 * Typesetting settings (design section 5.6), shown without covering the whole page, so every
 * change can be seen right away: at the bottom in portrait, as a full-height side panel in
 * landscape (decided by the user). Slider values are committed when the slider is released; each value can also
 * be typed in the field next to its slider (stage 8), which moves the panel above the keyboard.
 *
 * Fills the screen but only the panel takes touches; the rest goes to the views below.
 *
 * @param sidePanelOnLeft in landscape, put the panel on the left (for vertical text, whose pages
 *   start on the right) instead of the right, so the beginning of the page stays visible.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun EbookSettingsPanel(
    state: EbookSettingsUiState,
    sidePanelOnLeft: Boolean,
    onScopeChange: (SettingsScope) -> Unit,
    onSet: (Key, String) -> Unit,
    onResetScope: () -> Unit,
    onImportFont: () -> Unit,
    onDeleteFont: (ImportedFont) -> Unit,
    onPageTurn: (String) -> Unit,
    onGutterShadow: (Boolean) -> Unit,
    onClose: () -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    // Each tab keeps its own scroll position.
    val scrollStates = listOf(rememberScrollState(), rememberScrollState())
    val s = state.settings
    val config = LocalConfiguration.current
    val landscape = config.screenWidthDp > config.screenHeightDp
    // Portrait: keep most of the page visible above the panel.
    val maxHeight = (config.screenHeightDp * 0.3f).dp
    val sideWidth = minOf(420f, config.screenWidthDp * 0.5f).dp
    val alignment = when {
        !landscape -> Alignment.BottomCenter
        sidePanelOnLeft -> AbsoluteAlignment.TopLeft
        else -> AbsoluteAlignment.TopRight
    }
    // Stay clear of the system bars even while they are hidden: a bar shown by a swipe would
    // cover the controls, and on gesture navigation the screen edges are system gesture zones.
    val insets = when {
        !landscape -> WindowInsets.navigationBarsIgnoringVisibility
        sidePanelOnLeft -> WindowInsets.systemBarsIgnoringVisibility.only(WindowInsetsSides.Vertical + WindowInsetsSides.Left)
        else -> WindowInsets.systemBarsIgnoringVisibility.only(WindowInsetsSides.Vertical + WindowInsetsSides.Right)
    }
    // The keyboard of a value field pushes the panel up (portrait) or shortens it (landscape) instead of covering it.
    Box(Modifier.fillMaxSize().imePadding(), contentAlignment = alignment) {
        Surface(
            modifier = if (landscape) Modifier.fillMaxHeight().width(sideWidth) else Modifier.fillMaxWidth(),
            shape = when {
                !landscape -> RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp)
                sidePanelOnLeft -> AbsoluteRoundedCornerShape(topRight = 16.dp, bottomRight = 16.dp)
                else -> AbsoluteRoundedCornerShape(topLeft = 16.dp, bottomLeft = 16.dp)
            },
            tonalElevation = 3.dp,
            shadowElevation = 8.dp,
        ) {
            // A value field that is done gives the focus to the panel itself rather than clearing it: clearing it once
            // left a link of the page's first frame focused, and the browser scrolled that frame to it (stage 8).
            val park = remember { FocusRequester() }
            CompositionLocalProvider(LocalFieldDone provides { park.requestFocus() }) {
            Column(Modifier.windowInsetsPadding(insets).focusRequester(park).focusable()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TabRow(selectedTabIndex = tab, modifier = Modifier.weight(1f), divider = {}) {
                        Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text(stringResource(MR.strings.ebook_settings_text)) })
                        Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text(stringResource(MR.strings.ebook_settings_layout)) })
                    }
                    IconButton(onClick = onClose) {
                        Icon(Icons.Outlined.Close, contentDescription = stringResource(MR.strings.close))
                    }
                }
                HorizontalDivider()
                Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp)) {
                    Choices(
                        options = listOf(
                            SettingsScope.GLOBAL to MR.strings.ebook_scope_global,
                            SettingsScope.WORK to MR.strings.ebook_scope_work,
                            SettingsScope.FILE to MR.strings.ebook_scope_file,
                        ),
                        selected = state.scope,
                        onSelect = onScopeChange,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(MR.strings.ebook_scope_inherited),
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = onResetScope, enabled = state.scopeHasValues) {
                            Text(stringResource(MR.strings.ebook_scope_reset))
                        }
                    }
                }
                HorizontalDivider()
                Column(
                    modifier = (if (landscape) Modifier.weight(1f) else Modifier.heightIn(max = maxHeight))
                        .verticalScroll(scrollStates[tab])
                        .padding(horizontal = 20.dp, vertical = 8.dp),
                ) {
                    val over = state.overridden
                    if (tab == 0) {
                        FontSection(s.font, state.fonts, over[Key.FONT], onSet, onImportFont, onDeleteFont)
                        HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        SwitchSetting(MR.strings.ebook_bold, s.bold, over[Key.BOLD]) { onSet(Key.BOLD, it.toString()) }
                        StepSlider(
                            MR.strings.ebook_font_size, s.fontSize.toFloat(),
                            Range.fontSize.first.toFloat()..Range.fontSize.last.toFloat(), 1f, over[Key.FONT_SIZE], whole = true, unit = null,
                        ) { onSet(Key.FONT_SIZE, it.roundToInt().toString()) }
                        StepSlider(
                            MR.strings.ebook_line_height, s.lineHeight, Range.lineHeight, Range.LINE_HEIGHT_STEP, over[Key.LINE_HEIGHT],
                            whole = false, unit = null,
                        ) { onSet(Key.LINE_HEIGHT, EbookSettings.format(it)) }
                        StepSlider(
                            MR.strings.ebook_letter_spacing, s.letterSpacing, Range.letterSpacing, Range.LETTER_SPACING_STEP,
                            over[Key.LETTER_SPACING], whole = false, unit = "em",
                        ) { onSet(Key.LETTER_SPACING, EbookSettings.format(it)) }
                        OptionalSlider(
                            MR.strings.ebook_indent, s.indent, 2f, Range.indent, Range.INDENT_STEP, over[Key.INDENT],
                            unit = stringResource(MR.strings.ebook_unit_characters, "").trim(),
                        ) { onSet(Key.INDENT, it?.let(EbookSettings::format) ?: EbookSettings.BOOK) }
                        OptionalSlider(
                            MR.strings.ebook_paragraph_spacing, s.paragraphSpacing, 0.5f, Range.paragraphSpacing,
                            Range.PARAGRAPH_SPACING_STEP, over[Key.PARAGRAPH_SPACING], unit = "em",
                        ) { onSet(Key.PARAGRAPH_SPACING, it?.let(EbookSettings::format) ?: EbookSettings.BOOK) }
                    } else {
                        Label(MR.strings.ebook_writing_mode, over[Key.WRITING_MODE])
                        Choices(
                            options = listOf(
                                EbookSettings.BOOK to MR.strings.ebook_writing_mode_book,
                                EbookSettings.MODE_VERTICAL to MR.strings.ebook_writing_mode_vertical,
                                EbookSettings.MODE_HORIZONTAL to MR.strings.ebook_writing_mode_horizontal,
                            ),
                            selected = s.writingMode,
                            onSelect = { onSet(Key.WRITING_MODE, it) },
                        )
                        Spacer(Modifier.height(12.dp))
                        Label(MR.strings.ebook_page_direction, over[Key.PAGE_DIRECTION])
                        Choices(
                            options = listOf(
                                EbookSettings.DIRECTION_AUTO to MR.strings.ebook_page_direction_auto,
                                EbookSettings.DIRECTION_RTL to MR.strings.ebook_page_direction_rtl,
                                EbookSettings.DIRECTION_LTR to MR.strings.ebook_page_direction_ltr,
                            ),
                            selected = s.pageDirection,
                            onSelect = { onSet(Key.PAGE_DIRECTION, it) },
                        )
                        Text(
                            stringResource(MR.strings.ebook_page_direction_hint),
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(top = 4.dp),
                        )
                        Spacer(Modifier.height(12.dp))
                        Label(MR.strings.ebook_columns, over[Key.COLUMNS])
                        Choices(
                            options = listOf(
                                EbookSettings.COLUMNS_OFF to MR.strings.ebook_columns_off,
                                EbookSettings.COLUMNS_ON to MR.strings.ebook_columns_on,
                                EbookSettings.COLUMNS_LANDSCAPE to MR.strings.ebook_columns_landscape,
                            ),
                            selected = s.columns,
                            onSelect = { onSet(Key.COLUMNS, it) },
                        )
                        SwitchSetting(MR.strings.ebook_gutter_shadow, state.gutterShadow, null, onGutterShadow)
                        Text(
                            stringResource(MR.strings.ebook_gutter_shadow_hint),
                            style = MaterialTheme.typography.bodySmall,
                        )
                        HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        Label(MR.strings.ebook_margins, null)
                        val margin = Range.margin.first.toFloat()..Range.margin.last.toFloat()
                        val step = Range.MARGIN_STEP.toFloat()
                        // With two columns, each side margin stops where the two would leave less than 120 dp per
                        // column (stage 8): the page no longer jumps to one column when a margin is moved too far.
                        // Only when it limits the sides at all (a landscape screen leaves more than 120 + 120 dp).
                        val most = state.marginMost?.takeIf { it < 2 * Range.margin.last }
                        fun side(other: Int): ClosedFloatingPointRange<Float> =
                            if (most == null) margin else 0f..(most - other).coerceIn(Range.MARGIN_STEP, Range.margin.last).toFloat()
                        StepSlider(MR.strings.ebook_margin_top, s.marginTop.toFloat(), margin, step, over[Key.MARGIN_TOP], whole = true, unit = "dp") {
                            onSet(Key.MARGIN_TOP, it.roundToInt().toString())
                        }
                        StepSlider(MR.strings.ebook_margin_bottom, s.marginBottom.toFloat(), margin, step, over[Key.MARGIN_BOTTOM], whole = true, unit = "dp") {
                            onSet(Key.MARGIN_BOTTOM, it.roundToInt().toString())
                        }
                        if (most != null) {
                            Text(
                                stringResource(MR.strings.ebook_margins_two_columns, most),
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(top = 8.dp),
                            )
                            if (s.marginLeft + s.marginRight > most) {
                                Text(
                                    stringResource(MR.strings.ebook_margins_two_columns_over, s.marginLeft + s.marginRight),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                        StepSlider(MR.strings.ebook_margin_left, s.marginLeft.toFloat(), side(s.marginRight), step, over[Key.MARGIN_LEFT], whole = true, unit = "dp") {
                            onSet(Key.MARGIN_LEFT, it.roundToInt().toString())
                        }
                        StepSlider(MR.strings.ebook_margin_right, s.marginRight.toFloat(), side(s.marginLeft), step, over[Key.MARGIN_RIGHT], whole = true, unit = "dp") {
                            onSet(Key.MARGIN_RIGHT, it.roundToInt().toString())
                        }
                        HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        Label(MR.strings.ebook_page_turn, null)
                        Choices(
                            options = listOf(
                                PageTurnPreferences.NONE to MR.strings.ebook_page_turn_none,
                                PageTurnPreferences.SLIDE to MR.strings.ebook_page_turn_slide,
                                PageTurnPreferences.CURL to MR.strings.ebook_page_turn_curl,
                            ),
                            selected = state.pageTurn,
                            onSelect = onPageTurn,
                        )
                        Text(
                            stringResource(MR.strings.ebook_page_turn_hint),
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
                        )
                    }
                }
            }
            }
        }
    }
}

/** What a value field does when its value is done: give the focus to the panel (see [EbookSettingsPanel]). */
private val LocalFieldDone = staticCompositionLocalOf<(() -> Unit)?> { null }

private val SettingsScope.label: StringResource
    get() = when (this) {
        SettingsScope.GLOBAL -> MR.strings.ebook_scope_global
        SettingsScope.WORK -> MR.strings.ebook_scope_work
        SettingsScope.FILE -> MR.strings.ebook_scope_file
    }

/** Tells that a nearer level sets this item, so a change here is not what the page shows. */
@Composable
private fun OverriddenNote(level: SettingsScope?) {
    if (level == null) return
    Text(
        stringResource(MR.strings.ebook_scope_overridden, stringResource(level.label)),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.error,
    )
}

@Composable
private fun Label(text: StringResource, overridden: SettingsScope?) {
    Column(Modifier.padding(vertical = 4.dp)) {
        Text(stringResource(text), style = MaterialTheme.typography.titleSmall)
        OverriddenNote(overridden)
    }
}

/** An on/off setting (the switch sits at the end of the row, after the label). */
@Composable
private fun SwitchSetting(label: StringResource, checked: Boolean, overridden: SettingsScope?, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(label), style = MaterialTheme.typography.titleSmall)
            OverriddenNote(overridden)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun <T> Choices(options: List<Pair<T, StringResource>>, selected: T, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { i, (value, label) ->
            SegmentedButton(
                selected = value == selected,
                onClick = { if (value != selected) onSelect(value) },
                shape = SegmentedButtonDefaults.itemShape(index = i, count = options.size),
            ) { Text(stringResource(label), maxLines = 1) }
        }
    }
}

@Composable
private fun FontSection(
    font: String,
    fonts: List<ImportedFont>,
    overridden: SettingsScope?,
    onSet: (Key, String) -> Unit,
    onImportFont: () -> Unit,
    onDeleteFont: (ImportedFont) -> Unit,
) {
    Label(MR.strings.ebook_font, overridden)
    val builtIn = listOf(
        EbookSettings.FONT_BOOK to stringResource(MR.strings.ebook_font_book),
        EbookSettings.FONT_SANS to stringResource(MR.strings.ebook_font_sans),
        EbookSettings.FONT_SERIF to stringResource(MR.strings.ebook_font_serif),
    )
    // A deleted (or not restored) imported font falls back to the book's font, as on the page.
    val shown = if (builtIn.none { it.first == font } && fonts.none { it.id == font }) EbookSettings.FONT_BOOK else font
    builtIn.forEach { (id, label) -> FontRow(label, null, shown == id, { onSet(Key.FONT, id) }, null) }
    val noVertical = stringResource(MR.strings.ebook_font_no_vertical_short)
    fonts.forEach { f ->
        FontRow(f.name, noVertical.takeIf { !f.vertical }, shown == f.id, { onSet(Key.FONT, f.id) }) { onDeleteFont(f) }
    }
    // A button rather than a full-width row, so a scroll gesture starting here does not open the picker.
    OutlinedButton(onClick = onImportFont, modifier = Modifier.padding(start = 8.dp, top = 4.dp)) {
        Icon(Icons.Outlined.Add, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(stringResource(MR.strings.ebook_font_import))
    }
}

@Composable
private fun FontRow(label: String, note: String?, selected: Boolean, onSelect: () -> Unit, onDelete: (() -> Unit)?) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Column(Modifier.weight(1f)) {
            Text(label, maxLines = 1)
            if (note != null) Text(note, style = MaterialTheme.typography.bodySmall)
        }
        if (onDelete != null) {
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = stringResource(MR.strings.ebook_font_delete))
            }
        }
    }
}

@Composable
private fun StepSlider(
    label: StringResource,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    step: Float,
    overridden: SettingsScope?,
    whole: Boolean,
    unit: String?,
    onCommit: (Float) -> Unit,
) {
    var current by remember(value) { mutableFloatStateOf(value) }
    var invalid by remember { mutableStateOf(false) }
    val name = stringResource(label)
    Column(Modifier.padding(top = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(name, modifier = Modifier.weight(1f))
            NumberField(current, whole, range, name, { invalid = it }, onCommit)
            UnitLabel(unit)
        }
        if (invalid) RangeNote(range, whole)
        OverriddenNote(overridden)
        StepTrackSlider(
            current.coerceIn(range.start, range.endInclusive),
            { current = snap(it, range, step); invalid = false },
            { if (current != value) onCommit(current) },
            range,
            step,
        )
    }
}

/** A value that can also be left to the book ("依書籍"). */
@Composable
private fun OptionalSlider(
    label: StringResource,
    value: Float?,
    initial: Float,
    range: ClosedFloatingPointRange<Float>,
    step: Float,
    overridden: SettingsScope?,
    unit: String?,
    onCommit: (Float?) -> Unit,
) {
    val followBook = value == null
    var current by remember(value) { mutableFloatStateOf(value ?: initial) }
    var invalid by remember { mutableStateOf(false) }
    val name = stringResource(label)
    Column(Modifier.padding(top = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(name, modifier = Modifier.weight(1f))
            if (!followBook) {
                NumberField(current, false, range, name, { invalid = it }, onCommit)
                UnitLabel(unit)
                Spacer(Modifier.width(12.dp))
            }
            Text(stringResource(MR.strings.ebook_follow_book), style = MaterialTheme.typography.bodySmall)
            Switch(
                checked = followBook,
                onCheckedChange = { checked -> invalid = false; onCommit(if (checked) null else current) },
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        if (invalid && !followBook) RangeNote(range, false)
        OverriddenNote(overridden)
        if (!followBook) {
            StepTrackSlider(
                current.coerceIn(range.start, range.endInclusive),
                { current = snap(it, range, step); invalid = false },
                { if (current != value) onCommit(current) },
                range,
                step,
            )
        }
    }
}

@Composable
private fun UnitLabel(unit: String?) {
    if (unit != null) Text(unit, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 6.dp))
}

/** Under a value field: what can be typed, shown after a value outside it. */
@Composable
private fun RangeNote(range: ClosedFloatingPointRange<Float>, whole: Boolean) {
    val lo = numberText(range.start, whole)
    val hi = numberText(range.endInclusive, whole)
    Text(
        stringResource(if (whole) MR.strings.ebook_value_range_whole else MR.strings.ebook_value_range, lo, hi),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.error,
    )
}

private fun numberText(v: Float, whole: Boolean) = if (whole) v.roundToInt().toString() else EbookSettings.format(v)

/**
 * The value of a slider, typed in (stage 8, asked by the user). Applied with the keyboard's Done key or when the
 * field loses the focus. A number outside [range] (or not whole, for a [whole] value) is not applied: Done keeps
 * the field open and [onInvalid] gets true, so the row shows what can be typed; leaving the field puts the value
 * back. A typed value can be finer than the slider's step (to 0.01, margins to 1 dp). The value is selected when
 * the field gets the focus, so typing replaces it.
 */
@Composable
private fun NumberField(
    value: Float,
    whole: Boolean,
    range: ClosedFloatingPointRange<Float>,
    description: String,
    onInvalid: (Boolean) -> Unit,
    onCommit: (Float) -> Unit,
) {
    val shown = numberText(value, whole)
    // A new value from outside (the slider, another level, a commit) replaces what the field shows.
    var text by remember(shown) { mutableStateOf(TextFieldValue(shown)) }
    var focused by remember { mutableStateOf(false) }
    var selectAll by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val done = LocalFieldDone.current
    // After the tap that focused the field has placed the cursor.
    LaunchedEffect(selectAll) {
        if (selectAll) {
            text = text.copy(selection = TextRange(0, text.text.length))
            selectAll = false
        }
    }

    fun parsed(): Float? {
        // Some keyboards type a decimal comma.
        val v = text.text.trim().replace(',', '.').toFloatOrNull()?.takeIf { it.isFinite() } ?: return null
        if (v < range.start - EPSILON || v > range.endInclusive + EPSILON) return null
        if (whole && abs(v - v.roundToInt()) > EPSILON) return null
        val r = if (whole) v.roundToInt().toFloat() else Math.round(v * 100f) / 100f
        return r.coerceIn(range.start, range.endInclusive)
    }

    fun apply(): Boolean {
        val v = parsed()
        onInvalid(v == null)
        if (v != null && abs(v - value) > EPSILON) onCommit(v)
        return v != null
    }

    val colors = MaterialTheme.colorScheme
    BasicTextField(
        value = text,
        onValueChange = { text = it },
        modifier = Modifier
            .width(64.dp)
            .semantics { contentDescription = description }
            .onFocusChanged { f ->
                if (focused && !f.isFocused && !apply()) {
                    onInvalid(false)
                    text = TextFieldValue(shown)
                }
                if (!focused && f.isFocused) selectAll = true
                focused = f.isFocused
            },
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyMedium.copy(color = colors.onSurface, textAlign = TextAlign.End),
        keyboardOptions = KeyboardOptions(
            keyboardType = if (whole) KeyboardType.Number else KeyboardType.Decimal,
            imeAction = ImeAction.Done,
        ),
        keyboardActions = KeyboardActions(onDone = { if (apply()) done?.invoke() ?: focusManager.clearFocus() }),
        cursorBrush = SolidColor(colors.primary),
        decorationBox = { inner ->
            Box(
                Modifier
                    .border(1.dp, if (focused) colors.primary else colors.outline, RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                contentAlignment = Alignment.CenterEnd,
            ) { inner() }
        },
    )
}

private const val EPSILON = 0.0001f

/** A slider that snaps to [step] without drawing a dot for every stop (margins have 60). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StepTrackSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
    range: ClosedFloatingPointRange<Float>,
    step: Float,
) {
    Slider(
        value = value,
        onValueChange = onValueChange,
        onValueChangeFinished = onValueChangeFinished,
        valueRange = range,
        steps = stepsOf(range, step),
        track = { sliderState -> SliderDefaults.Track(sliderState = sliderState, drawTick = { _, _ -> }) },
    )
}

/** Number of stops between the ends of a slider. */
private fun stepsOf(range: ClosedFloatingPointRange<Float>, step: Float): Int =
    (((range.endInclusive - range.start) / step).roundToInt() - 1).coerceAtLeast(0)

private fun snap(v: Float, range: ClosedFloatingPointRange<Float>, step: Float): Float {
    val snapped = ((v - range.start) / step).roundToInt() * step + range.start
    return (Math.round(snapped * 100f) / 100f).coerceIn(range.start, range.endInclusive)
}
