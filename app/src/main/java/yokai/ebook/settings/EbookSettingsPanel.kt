package yokai.ebook.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.stringResource
import kotlin.math.roundToInt
import yokai.ebook.settings.EbookSettings.Companion.Range
import yokai.ebook.settings.EbookSettings.Key
import yokai.i18n.MR

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
)

/**
 * Typesetting settings (design section 5.6), shown at the bottom of the reader without covering
 * the rest of the page, so every change can be seen right away. Slider values are committed when
 * the slider is released.
 */
@Composable
fun EbookSettingsPanel(
    state: EbookSettingsUiState,
    onScopeChange: (SettingsScope) -> Unit,
    onSet: (Key, String) -> Unit,
    onResetScope: () -> Unit,
    onImportFont: () -> Unit,
    onDeleteFont: (ImportedFont) -> Unit,
    onClose: () -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    // Each tab keeps its own scroll position.
    val scrollStates = listOf(rememberScrollState(), rememberScrollState())
    val s = state.settings
    // Keep most of the page visible, so changes can be seen while adjusting.
    val maxHeight = (LocalConfiguration.current.screenHeightDp * 0.3f).dp
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
    ) {
        Column(Modifier.navigationBarsPadding()) {
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
                modifier = Modifier
                    .heightIn(max = maxHeight)
                    .verticalScroll(scrollStates[tab])
                    .padding(horizontal = 20.dp, vertical = 8.dp),
            ) {
                val over = state.overridden
                if (tab == 0) {
                    FontSection(s.font, state.fonts, over[Key.FONT], onSet, onImportFont, onDeleteFont)
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    StepSlider(
                        MR.strings.ebook_font_size, s.fontSize.toFloat(),
                        Range.fontSize.first.toFloat()..Range.fontSize.last.toFloat(), 1f, over[Key.FONT_SIZE],
                        { it.roundToInt().toString() },
                    ) { onSet(Key.FONT_SIZE, it.roundToInt().toString()) }
                    StepSlider(
                        MR.strings.ebook_line_height, s.lineHeight, Range.lineHeight, Range.LINE_HEIGHT_STEP, over[Key.LINE_HEIGHT],
                        { EbookSettings.format(it) },
                    ) { onSet(Key.LINE_HEIGHT, EbookSettings.format(it)) }
                    StepSlider(
                        MR.strings.ebook_letter_spacing, s.letterSpacing, Range.letterSpacing, Range.LETTER_SPACING_STEP,
                        over[Key.LETTER_SPACING], { "${EbookSettings.format(it)} em" },
                    ) { onSet(Key.LETTER_SPACING, EbookSettings.format(it)) }
                    OptionalSlider(
                        MR.strings.ebook_indent, s.indent, 2f, Range.indent, Range.INDENT_STEP, over[Key.INDENT],
                        { stringResource(MR.strings.ebook_unit_characters, EbookSettings.format(it)) },
                    ) { onSet(Key.INDENT, it?.let(EbookSettings::format) ?: EbookSettings.BOOK) }
                    OptionalSlider(
                        MR.strings.ebook_paragraph_spacing, s.paragraphSpacing, 0.5f, Range.paragraphSpacing,
                        Range.PARAGRAPH_SPACING_STEP, over[Key.PARAGRAPH_SPACING], { "${EbookSettings.format(it)} em" },
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
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    Label(MR.strings.ebook_margins, null)
                    val margin = Range.margin.first.toFloat()..Range.margin.last.toFloat()
                    val step = Range.MARGIN_STEP.toFloat()
                    val dp: @Composable (Float) -> String = { "${it.roundToInt()} dp" }
                    StepSlider(MR.strings.ebook_margin_top, s.marginTop.toFloat(), margin, step, over[Key.MARGIN_TOP], dp) {
                        onSet(Key.MARGIN_TOP, it.roundToInt().toString())
                    }
                    StepSlider(MR.strings.ebook_margin_bottom, s.marginBottom.toFloat(), margin, step, over[Key.MARGIN_BOTTOM], dp) {
                        onSet(Key.MARGIN_BOTTOM, it.roundToInt().toString())
                    }
                    StepSlider(MR.strings.ebook_margin_left, s.marginLeft.toFloat(), margin, step, over[Key.MARGIN_LEFT], dp) {
                        onSet(Key.MARGIN_LEFT, it.roundToInt().toString())
                    }
                    StepSlider(MR.strings.ebook_margin_right, s.marginRight.toFloat(), margin, step, over[Key.MARGIN_RIGHT], dp) {
                        onSet(Key.MARGIN_RIGHT, it.roundToInt().toString())
                    }
                }
            }
        }
    }
}

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
    format: @Composable (Float) -> String,
    onCommit: (Float) -> Unit,
) {
    var current by remember(value) { mutableFloatStateOf(value) }
    Column(Modifier.padding(top = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(label), modifier = Modifier.weight(1f))
            Text(format(current), style = MaterialTheme.typography.bodyMedium)
        }
        OverriddenNote(overridden)
        StepTrackSlider(current, { current = snap(it, range, step) }, { if (current != value) onCommit(current) }, range, step)
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
    format: @Composable (Float) -> String,
    onCommit: (Float?) -> Unit,
) {
    val followBook = value == null
    var current by remember(value) { mutableFloatStateOf(value ?: initial) }
    Column(Modifier.padding(top = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(label), modifier = Modifier.weight(1f))
            if (!followBook) {
                Text(format(current), style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.width(12.dp))
            }
            Text(stringResource(MR.strings.ebook_follow_book), style = MaterialTheme.typography.bodySmall)
            Switch(
                checked = followBook,
                onCheckedChange = { checked -> onCommit(if (checked) null else current) },
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        OverriddenNote(overridden)
        if (!followBook) {
            StepTrackSlider(current, { current = snap(it, range, step) }, { if (current != value) onCommit(current) }, range, step)
        }
    }
}

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
