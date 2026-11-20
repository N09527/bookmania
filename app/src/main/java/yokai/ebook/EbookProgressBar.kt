package yokai.ebook

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * The bar shown at the bottom with the menu: page information and a slider over the whole book
 * (design question 3). The slider runs from right to left for books whose pages turn that way, like
 * the manga reader's page slider for right-to-left books. While dragging it shows where the slider is
 * (percentage and the table of contents entry there); the book moves when the slider is released.
 *
 * @param progress fraction of the book (0..1) at the page shown, or null while the book's text is still
 *   being counted (the slider is disabled then).
 * @param titleAt the table of contents entry at a fraction of the book, for the label while dragging.
 */
@Composable
fun EbookProgressBar(
    pageInfo: String,
    progress: Float?,
    rightToLeft: Boolean,
    titleAt: (Float) -> String?,
    onSeek: (Float) -> Unit,
    sliderLabel: String,
    modifier: Modifier = Modifier,
) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    val shown = dragging ?: progress
    Surface(modifier = modifier.fillMaxWidth(), tonalElevation = 3.dp, shadowElevation = 4.dp) {
        Column(
            Modifier
                .windowInsetsPadding(WindowInsets.navigationBars.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
                .padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = dragging?.let { titleAt(it) } ?: pageInfo,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (shown != null) {
                    Text(text = "${(shown * 100).roundToInt()}%", style = MaterialTheme.typography.bodySmall)
                }
            }
            CompositionLocalProvider(LocalLayoutDirection provides if (rightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                Slider(
                    value = shown ?: 0f,
                    onValueChange = { dragging = it },
                    onValueChangeFinished = {
                        dragging?.let(onSeek)
                        dragging = null
                    },
                    enabled = progress != null,
                    modifier = Modifier.semantics { contentDescription = sliderLabel },
                )
            }
        }
    }
}
