package yokai.ebook

import android.app.Activity
import android.view.View
import androidx.appcompat.app.AlertDialog
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.mikepenz.fastadapter.FastAdapter
import com.mikepenz.fastadapter.adapters.ItemAdapter
import com.mikepenz.fastadapter.listeners.ClickEventHook
import eu.kanade.tachiyomi.data.database.models.Chapter
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.ui.reader.chapter.ReaderChapterItem
import eu.kanade.tachiyomi.util.chapter.ChapterSort
import eu.kanade.tachiyomi.util.system.launchIO
import eu.kanade.tachiyomi.util.system.withIOContext
import uy.kohesive.injekt.injectLazy
import yokai.domain.chapter.interactor.GetChapter
import yokai.domain.chapter.interactor.UpdateChapter
import yokai.domain.chapter.models.ChapterUpdate
import yokai.i18n.MR
import yokai.util.lang.getString

/**
 * The text reader's chapter panel (design section 5.4): the other chapters (files) of the work, filtered
 * and sorted as the image reader's chapter sheet lists them (ReaderViewModel.getChapters), with the same
 * list item. As there, a tap opens a chapter, a long press marks it read or unread, and the bookmark
 * button sets or clears its bookmark.
 *
 * @param current the chapter open now, the reading session's own object, so that what is changed here is
 *   kept when the session next saves the chapter.
 */
class ChapterPanel(
    private val activity: Activity,
    private val manga: Manga,
    private val current: Chapter,
    private val onOpen: (Chapter) -> Unit,
) {
    private val getChapter: GetChapter by injectLazy()
    private val updateChapter: UpdateChapter by injectLazy()
    private val itemAdapter = ItemAdapter<ReaderChapterItem>()
    private var dialog: AlertDialog? = null

    suspend fun show() {
        val items = withIOContext { load() }
        if (activity.isFinishing || activity.isDestroyed) return
        itemAdapter.set(items)
        val adapter = FastAdapter.with(itemAdapter)
        adapter.onClickListener = { _, _, item, _ ->
            dialog?.dismiss()
            if (item.chapter.id != current.id) onOpen(item.chapter)
            true
        }
        adapter.onLongClickListener = { _, _, item, position ->
            toggleRead(item.chapter)
            adapter.notifyAdapterItemChanged(position)
            true
        }
        adapter.addEventHook(
            object : ClickEventHook<ReaderChapterItem>() {
                override fun onBind(viewHolder: RecyclerView.ViewHolder): View? =
                    (viewHolder as? ReaderChapterItem.ViewHolder)?.binding?.bookmarkButton

                override fun onClick(v: View, position: Int, fastAdapter: FastAdapter<ReaderChapterItem>, item: ReaderChapterItem) {
                    toggleBookmark(item.chapter)
                    fastAdapter.notifyAdapterItemChanged(position)
                }
            },
        )
        val list = RecyclerView(activity).apply {
            layoutManager = LinearLayoutManager(activity)
            this.adapter = adapter
            scrollToPosition(items.indexOfFirst { it.isCurrent }.coerceAtLeast(0))
        }
        dialog = MaterialAlertDialogBuilder(activity)
            .setTitle(activity.getString(MR.strings.chapters))
            .setView(list)
            .setNegativeButton(activity.getString(MR.strings.cancel), null)
            .show()
    }

    private suspend fun load(): List<ReaderChapterItem> {
        val chapters = getChapter.awaitAll(manga, true)
        val sorted = ChapterSort(manga).getChaptersSorted(
            chapters,
            filterForReader = true,
            currentChapter = chapters.find { it.id == current.id } ?: current,
        )
        return sorted.map { chapter ->
            if (chapter.id == current.id) ReaderChapterItem(current, manga, true) else ReaderChapterItem(chapter, manga, false)
        }
    }

    /** As the image reader's chapter sheet (ReaderViewModel.toggleRead). */
    private fun toggleRead(chapter: Chapter) {
        chapter.read = !chapter.read
        val update = ChapterUpdate(
            id = chapter.id!!,
            read = chapter.read,
            bookmark = chapter.bookmark,
            lastPageRead = if (chapter.read) chapter.last_page_read.toLong() else 0L,
            pagesLeft = if (chapter.read) 0L else chapter.pages_left.toLong(),
        )
        launchIO { updateChapter.await(update) }
    }

    /** As the image reader's chapter sheet (ReaderViewModel.toggleBookmark). */
    private fun toggleBookmark(chapter: Chapter) {
        chapter.bookmark = !chapter.bookmark
        val update = ChapterUpdate(
            id = chapter.id!!,
            read = chapter.read,
            bookmark = chapter.bookmark,
            lastPageRead = chapter.last_page_read.toLong(),
            pagesLeft = chapter.pages_left.toLong(),
        )
        launchIO { updateChapter.await(update) }
    }
}
