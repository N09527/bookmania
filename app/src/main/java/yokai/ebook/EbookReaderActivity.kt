package yokai.ebook

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.PointF
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.TypedValue
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import co.touchlab.kermit.Logger
import com.hippo.unifile.UniFile
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import dev.icerock.moko.resources.compose.stringResource
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.data.database.models.Chapter
import eu.kanade.tachiyomi.databinding.EbookReaderActivityBinding
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import eu.kanade.tachiyomi.source.SourceManager
import eu.kanade.tachiyomi.ui.base.activity.BaseActivity
import eu.kanade.tachiyomi.ui.reader.ReaderActivity
import eu.kanade.tachiyomi.ui.reader.settings.ReaderBackgroundColor
import eu.kanade.tachiyomi.ui.reader.viewer.ViewerNavigation
import eu.kanade.tachiyomi.ui.reader.viewer.navigation.DisabledNavigation
import eu.kanade.tachiyomi.ui.reader.viewer.navigation.EdgeNavigation
import eu.kanade.tachiyomi.ui.reader.viewer.navigation.KindlishNavigation
import eu.kanade.tachiyomi.ui.reader.viewer.navigation.LNavigation
import eu.kanade.tachiyomi.ui.reader.viewer.navigation.RightAndLeftNavigation
import eu.kanade.tachiyomi.util.system.getResourceColor
import eu.kanade.tachiyomi.util.system.launchIO
import eu.kanade.tachiyomi.util.system.toast
import eu.kanade.tachiyomi.util.system.withIOContext
import eu.kanade.tachiyomi.util.system.withUIContext
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.math.abs
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import uy.kohesive.injekt.injectLazy
import yokai.core.ebook.BookStats
import yokai.core.ebook.CorruptBookException
import yokai.core.ebook.DrmProtectedException
import yokai.core.ebook.Publication
import yokai.core.ebook.TocEntry
import yokai.core.ebook.UnsupportedBookException
import yokai.core.ebook.WritingModeHint
import yokai.domain.chapter.interactor.GetChapter
import yokai.domain.chapter.interactor.UpdateChapter
import yokai.domain.history.interactor.UpsertHistory
import yokai.domain.library.LibraryPreferences
import yokai.domain.manga.interactor.GetManga
import yokai.domain.track.interactor.GetTrack
import yokai.ebook.data.EbookDatabase
import yokai.ebook.data.EbookLocator
import yokai.ebook.data.ReadingProgress
import yokai.ebook.settings.BookKey
import yokai.ebook.settings.EbookSettings
import yokai.ebook.settings.EbookSettingsPanel
import yokai.ebook.settings.EbookSettingsStore
import yokai.ebook.settings.EbookSettingsUiState
import yokai.ebook.settings.FontStore
import yokai.ebook.settings.ImportedFont
import yokai.ebook.settings.SettingsScope
import yokai.gutter.GutterPreferences
import yokai.gutter.GutterShadowView
import yokai.i18n.MR
import yokai.pageturn.CurlEdge
import yokai.pageturn.PageTurnPreferences
import yokai.pageturn.PageTurner
import yokai.presentation.theme.YokaiTheme
import yokai.util.lang.getString

/**
 * Text reader for Local Source EPUB, MOBI and AZW3 books (one column; typesetting settings in three
 * levels, see [EbookSettingsStore]).
 *
 * The book is rendered by the shell (assets/ebook) in a WebView that can only reach the virtual
 * origin served by [EbookRequestHandler]. All input is handled here; the shell is driven with
 * evaluateJavascript and polled while it lays out a document.
 */
class EbookReaderActivity : BaseActivity<EbookReaderActivityBinding>() {

    private val getManga: GetManga by injectLazy()
    private val getChapter: GetChapter by injectLazy()
    private val sourceManager: SourceManager by injectLazy()
    private val updateChapter: UpdateChapter by injectLazy()
    private val upsertHistory: UpsertHistory by injectLazy()
    private val getTrack: GetTrack by injectLazy()
    private val libraryPreferences: LibraryPreferences by injectLazy()
    private val ebookDb by lazy { EbookDatabase.get(this) }

    private val requestHandler by lazy { EbookRequestHandler(assets) }
    private val settingsStore by lazy { EbookSettingsStore(preferences.preferenceStore) }
    private val fontStore by lazy { FontStore(this, preferences.preferenceStore) }
    private val pageTurnPreferences by lazy { PageTurnPreferences(preferences.preferenceStore) }
    private val gutterPreferences by lazy { GutterPreferences(preferences.preferenceStore) }
    /** Plays the page turn animation (see [turnPage]). */
    private var pageTurner: PageTurner? = null
    /** Page turns run one after another, so a quick second tap waits for the first instead of being lost. */
    private val turnLock = Mutex()
    private var turnJob: Job? = null
    /** A turn into the next or previous document, played once its layout is ready (see [awaitLayout]). */
    private var pendingTurn: PageTurner.Turn? = null
    private var pendingTurnJob: Job? = null
    private var webView: WebView? = null
    private var shellLoaded = false

    private var publication: Publication? = null
    private var manga: Manga? = null
    private var chapter: Chapter? = null
    private var spineIndex = 0
    private var bookKey: BookKey? = null
    private var bookFile: UniFile? = null
    /** Saves progress, read state and reading time (see [ReadingSession]). */
    private var session: ReadingSession? = null
    /** Where to open the book (a saved position), used once when the shell is ready. */
    private var restoreTarget: EbookLocator? = null
    /** The position shown now, saved shortly after it changes and when the reader is paused. */
    private var currentLocator: EbookLocator? = null
    private var saveJob: Job? = null
    private val saveLock = Mutex()
    /** Page shown and pages of the open document in the current layout, saved with [currentLocator]. */
    private var currentPage = 0
    private var currentDocPages = 1
    private var settings = EbookSettings.DEFAULTS
    /** The book's own writing mode, used while the setting is "依書籍". */
    private var bookVertical = false
    /** Resolved writing mode of the page. */
    private var vertical = false
    /** Whether the next page is on the left (taps, swipes and arrow keys follow it). */
    private var rtl = false
    /** Settings the shell currently lays out with; a change re-lays out the open document. */
    private var appliedJson: String? = null
    private var pendingRelayout = false
    private var page = 0
    private var pages = 1
    /** Pages shown side by side (2 in two-column mode). */
    private var columns = 1
    /** The fold's shadow over the page (stage 7), and where the shell puts the gap of two columns (CSS px). */
    private var gutterView: GutterShadowView? = null
    private var gutterCss: Double? = null
    /** The largest left + right margins that keep two columns, when the settings ask for two here (stage 8). */
    private var marginMost: Int? = null

    private var busy = false
    private var waitJob: Job? = null
    private var resizeJob: Job? = null
    private var menuVisible = false
    private lateinit var gestures: GestureDetector
    private lateinit var insetsController: WindowInsetsControllerCompat

    private var backgroundColor = Color.WHITE
    private var textColor = Color.BLACK

    /** The settings panel, or null when it is closed. */
    private var panel by mutableStateOf<EbookSettingsUiState?>(null)

    /** The bottom bar shown with the menu: page information and the whole-book slider. */
    private var barVisible by mutableStateOf(false)
    private var pageInfoText by mutableStateOf("")
    private var bookProgress by mutableStateOf<Float?>(null)
    private var rtlState by mutableStateOf(false)
    private val fontPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) onFontPicked(uri)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = EbookReaderActivityBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val fullscreen = preferences.fullscreen().get()
        WindowCompat.setDecorFitsSystemWindows(window, !fullscreen)
        insetsController = WindowCompat.getInsetsController(window, window.decorView)
        insetsController.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (preferences.keepScreenOn().get()) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // With the status bar padding the toolbar must also grow, or its subtitle is cut off.
        val actionBarSize = TypedValue().let {
            if (theme.resolveAttribute(android.R.attr.actionBarSize, it, true)) {
                TypedValue.complexToDimensionPixelSize(it.data, resources.displayMetrics)
            } else {
                binding.toolbar.minimumHeight
            }
        }
        // Left and right too: in landscape the navigation bar is at a side and would cover the buttons.
        ViewCompat.setOnApplyWindowInsetsListener(binding.toolbar) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.updatePadding(left = bars.left, top = bars.top, right = bars.right)
            v.minimumHeight = actionBarSize + bars.top
            insets
        }

        resolveColors()
        binding.root.setBackgroundColor(backgroundColor)
        binding.errorTitle.setTextColor(textColor)
        binding.errorMessage.setTextColor(textColor)
        binding.errorBack.text = getString(MR.strings.back)
        binding.errorBack.setOnClickListener { finish() }

        binding.toolbar.setNavigationIcon(R.drawable.ic_arrow_back_24dp)
        binding.toolbar.setNavigationIconTint(getResourceColor(R.attr.colorOnSurface))
        binding.toolbar.setNavigationOnClickListener { finish() }
        binding.toolbar.menu.add(Menu.NONE, MENU_CHAPTERS, Menu.NONE, getString(MR.strings.chapters)).apply {
            setIcon(R.drawable.ic_view_list_24dp)
            iconTintList = ColorStateList.valueOf(getResourceColor(R.attr.colorOnSurface))
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            isVisible = false // until the chapter is known
        }
        binding.toolbar.menu.add(Menu.NONE, MENU_TOC, Menu.NONE, getString(MR.strings.ebook_toc)).apply {
            setIcon(R.drawable.ic_format_list_numbered_24dp)
            iconTintList = ColorStateList.valueOf(getResourceColor(R.attr.colorOnSurface))
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            isVisible = false // until a book is open
        }
        binding.toolbar.menu.add(Menu.NONE, MENU_SETTINGS, Menu.NONE, getString(MR.strings.ebook_settings)).apply {
            setIcon(R.drawable.ic_tune_24dp)
            iconTintList = ColorStateList.valueOf(getResourceColor(R.attr.colorOnSurface))
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            isVisible = false // until a book is open
        }
        binding.toolbar.menu.add(Menu.NONE, MENU_OPEN_AS_IMAGES, Menu.CATEGORY_SECONDARY, getString(MR.strings.ebook_open_as_images)).apply {
            setShowAsAction(MenuItem.SHOW_AS_ACTION_NEVER)
            isVisible = false // EPUB only, once it is open
        }
        binding.toolbar.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                MENU_SETTINGS -> openSettings()
                MENU_TOC -> showToc()
                MENU_CHAPTERS -> showChapters()
                MENU_OPEN_AS_IMAGES -> {
                    val m = manga
                    val c = chapter
                    if (m != null && c != null) {
                        lifecycleScope.launch {
                            // Written before the image reader reads the chapter: it starts from these page
                            // numbers (EbookRouter.fitImageReaderPage).
                            writePosition()
                            EbookRouter.openAsImages(this@EbookReaderActivity, m, c)
                        }
                    }
                }
                else -> return@setOnMenuItemClickListener false
            }
            true
        }
        binding.root.addView(
            ComposeView(this).apply {
                // Fills the screen so the panel can sit at the bottom or (landscape) at a side; touches
                // outside the panel are not consumed and reach the touch layer below.
                layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                elevation = resources.displayMetrics.density * 16 // above the toolbar and the page number
                setContent {
                    YokaiTheme {
                        if (barVisible) {
                            Box(Modifier.fillMaxSize()) {
                                EbookProgressBar(
                                    pageInfo = pageInfoText,
                                    progress = bookProgress,
                                    rightToLeft = rtlState,
                                    titleAt = ::tocTitleAt,
                                    onSeek = ::seekBook,
                                    sliderLabel = stringResource(MR.strings.ebook_book_progress),
                                    modifier = Modifier.align(Alignment.BottomCenter),
                                )
                            }
                        }
                        panel?.let { state ->
                            EbookSettingsPanel(
                                state = state,
                                sidePanelOnLeft = vertical,
                                onScopeChange = ::showPanel,
                                onSet = ::onSettingChanged,
                                onResetScope = ::resetScope,
                                onImportFont = ::importFont,
                                onDeleteFont = ::confirmDeleteFont,
                                onPageTurn = ::onPageTurnChanged,
                                onGutterShadow = ::onGutterShadowChanged,
                                onClose = { panel = null },
                            )
                        }
                    }
                }
            },
        )
        requestHandler.fontFile = { id -> fontStore.file(id) }
        pageTurner = PageTurner(window, binding.webContainer, binding.root)

        gestures = GestureDetector(this, TouchListener())
        binding.touchLayer.setOnTouchListener { _, event ->
            gestures.onTouchEvent(event)
            true
        }

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    // On the error screen the toolbar stays visible; back always leaves.
                    when {
                        panel != null -> panel = null
                        menuVisible && !binding.errorPanel.isVisible -> setMenuVisible(false)
                        else -> finish()
                    }
                }
            },
        )
        setMenuVisible(false)

        val mangaId = intent.getLongExtra(EXTRA_MANGA, -1L)
        val chapterId = intent.getLongExtra(EXTRA_CHAPTER, -1L)
        if (mangaId < 0 || chapterId < 0) {
            finish()
            return
        }
        lifecycleScope.launch { load(mangaId, chapterId) }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        endTurn() // the copies of the page no longer fit
        super.onConfigurationChanged(newConfig)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Re-apply after dialogs and when the window is first shown (hiding in onCreate is not
        // always honoured on older Android versions).
        if (hasFocus) applySystemBars()
    }

    override fun onResume() {
        super.onResume()
        session?.startTimer()
    }

    override fun onPause() {
        endTurn()
        // Write what is shown now and the reading time, also when the reader is being closed.
        saveJob?.cancel()
        persistPosition()
        val readingSession = session
        val span = readingSession?.stopTimer()
        val readManga = manga
        launchIO {
            if (readingSession != null && span != null) {
                runCatching { readingSession.saveReadingTime(span.first, span.second) }
                    .onFailure { Logger.e(it) { "Saving the reading time failed" } }
            }
            // Leaving the reader (or the app): the progress goes to the WebDAV sync.
            readManga?.let { Injekt.get<yokai.sync.SyncManager>().requestPush(it) }
        }
        super.onPause()
    }

    override fun onDestroy() {
        waitJob?.cancel()
        resizeJob?.cancel()
        endTurn()
        pageTurner?.release()
        webView?.let {
            (it.parent as? android.view.ViewGroup)?.removeView(it)
            it.destroy()
        }
        webView = null
        requestHandler.publication = null
        val pub = publication
        publication = null
        if (pub != null) runCatching { pub.close() }
        super.onDestroy()
    }

    // region Loading

    private suspend fun load(mangaId: Long, chapterId: Long) {
        binding.progress.isVisible = true
        val result = withIOContext {
            runCatching {
                val manga = getManga.awaitById(mangaId) ?: error("Manga $mangaId not found")
                val chapter = getChapter.awaitById(chapterId) ?: error("Chapter $chapterId not found")
                val source = sourceManager.getOrStub(manga.source) as? LocalSource
                    ?: throw UnsupportedBookException("Only Local Source books can be read as text")
                val file = when (val format = source.getFormat(chapter)) {
                    is LocalSource.Format.Epub -> format.file
                    is LocalSource.Format.Ebook -> format.file
                    else -> throw UnsupportedBookException("Not a text book")
                }
                Loaded(manga, chapter, file, LocalEbooks.open(file, this@EbookReaderActivity))
            }
        }
        if (isDestroyed) {
            result.getOrNull()?.publication?.close()
            return
        }
        val loaded = result.getOrElse {
            binding.progress.isVisible = false
            showError(it)
            return
        }
        val (manga, chapter, file, pub) = loaded
        this.manga = manga
        this.chapter = chapter
        // Also on the error screens below: another chapter of the work can be opened from there.
        binding.toolbar.menu.findItem(MENU_CHAPTERS)?.isVisible = true
        bookFile = file
        publication = pub
        if (pub.spine.isEmpty()) {
            binding.progress.isVisible = false
            showError(getString(MR.strings.ebook_cannot_open_title), getString(MR.strings.ebook_no_content))
            return
        }
        val key = BookKey(manga.source, manga.url, chapter.url)
        bookKey = key
        val readingSession = ReadingSession(
            manga, chapter, key, ebookDb, preferences, libraryPreferences, getChapter, updateChapter, upsertHistory, getTrack,
        )
        restoreTarget = withIOContext {
            // The WebDAV sync: the other devices' progress first (at most a few seconds).
            Injekt.get<yokai.sync.SyncManager>().pullBeforeReading(manga)
            readingSession.init()
            readingSession.positionToRestore(intent.getBooleanExtra(EXTRA_SWITCHED_FROM_IMAGES, false))
                ?: estimatedPosition(chapter, file, key, pub.spine.size, readingSession)
        }
        session = readingSession
        readingSession.startTimer()
        binding.progress.isVisible = false
        settings = settingsStore.effective(key)
        bookVertical = pub.writingModeHint == WritingModeHint.VERTICAL
        resolveMode()
        binding.toolbar.title = pub.metadata.title ?: chapter.name
        binding.toolbar.subtitle = manga.title
        binding.toolbar.menu.findItem(MENU_SETTINGS)?.isVisible = true
        binding.toolbar.menu.findItem(MENU_TOC)?.isVisible = true
        binding.toolbar.menu.findItem(MENU_OPEN_AS_IMAGES)?.isVisible = EbookRouter.canOpenAsImages(chapter)
        requestHandler.publication = pub
        createWebView()
        loadCharCounts()
    }

    private data class Loaded(val manga: Manga, val chapter: Chapter, val file: UniFile, val publication: Publication)

    /**
     * Character counts of the book's documents for whole-book progress: cached in ebook.db for this
     * version of the file, else counted from a separate copy of the book (the open one serves the WebView).
     */
    private fun charCounts(file: UniFile, key: BookKey, spineSize: Int): IntArray? {
        val size = file.length()
        val modified = file.lastModified()
        ebookDb.info(key)?.countsFor(size, modified)?.takeIf { it.size == spineSize }?.let { return it }
        val counts = runCatching { LocalEbooks.open(file, this).use { BookStats.charCounts(it) } }
            .onFailure { Logger.w(it) { "Counting the book's text failed" } }
            .getOrNull() ?: return null
        ebookDb.updateInfo(key) { it.copy(fileSize = size, fileModified = modified, charCounts = counts) }
        return counts.takeIf { it.size == spineSize }
    }

    /**
     * Without a saved position (e.g. a backup made without one) but with a page in the chapter list,
     * starts near that page: its fraction of the book, located with the character counts. Like the
     * manga reader, a read chapter starts from the beginning.
     */
    private fun estimatedPosition(chapter: Chapter, file: UniFile, key: BookKey, spineSize: Int, session: ReadingSession): EbookLocator? {
        val read = chapter.last_page_read
        val left = chapter.pages_left
        if (chapter.read || read <= 0 || left <= 1) return null
        val counts = charCounts(file, key, spineSize) ?: return null
        val progress = ReadingProgress(counts).also { session.progress = it }
        val (spine, fraction) = progress.locate(read.toDouble() / (read + left))
        val href = publication?.spine?.getOrNull(spine)?.href ?: return null
        return EbookLocator(spine = spine, href = href, progression = fraction)
    }

    /** Counts the text in the background; whole-book progress (slider, page estimates) waits for it. */
    private fun loadCharCounts() {
        val file = bookFile ?: return
        val key = bookKey ?: return
        val size = spine.size
        if (session?.progress != null) return
        lifecycleScope.launch {
            val counts = withIOContext { charCounts(file, key, size) } ?: return@launch
            session?.progress = ReadingProgress(counts)
            capturePosition() // the page estimate in the chapter list can now be written
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView() {
        val wv = try {
            WebView(this)
        } catch (e: Throwable) {
            // No usable WebView package on the device (missing, disabled or updating).
            Logger.e(e) { "WebView unavailable" }
            showError(getString(MR.strings.ebook_cannot_open_title), e.message ?: e.javaClass.simpleName)
            return
        }
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        wv.settings.apply {
            javaScriptEnabled = true // for the shell only; book frames are sandboxed without scripts
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
            domStorageEnabled = false
            setGeolocationEnabled(false)
            blockNetworkLoads = true
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture = true
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            textZoom = 100
            cacheMode = WebSettings.LOAD_NO_CACHE
            safeBrowsingEnabled = false
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(wv.settings, false)
        }
        wv.isVerticalScrollBarEnabled = false
        wv.isHorizontalScrollBarEnabled = false
        wv.overScrollMode = View.OVER_SCROLL_NEVER
        wv.isLongClickable = false
        wv.isFocusable = false
        wv.isFocusableInTouchMode = false
        wv.isHapticFeedbackEnabled = false
        wv.setBackgroundColor(backgroundColor)
        wv.webViewClient = ReaderWebViewClient()
        wv.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (BuildConfig.DEBUG) Logger.d { "ebook console: ${message.message()}" }
                return true
            }
        }
        // The shell lays the document out again by itself when the viewport changes (rotation, split
        // screen); page, page count and columns change with it, so read them again once it is done.
        wv.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) {
                gutterView?.show(null) // until the new layout tells where the columns are
                refreshAfterResize()
            }
        }
        binding.webContainer.addView(wv)
        // Above the page in the same container, so the page turn's copies of the page include the shadow.
        gutterView = GutterShadowView(this).also { binding.webContainer.addView(it) }
        webView = wv
        busy = true
        binding.progress.isVisible = true
        wv.loadUrl(EbookRequestHandler.SHELL_URL)
    }

    private inner class ReaderWebViewClient : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse =
            requestHandler.handle(request.url)

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

        override fun onPageFinished(view: WebView, url: String) {
            if (!shellLoaded && url == EbookRequestHandler.SHELL_URL) {
                shellLoaded = true
                busy = false
                openInitial()
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // The renderer crashed or was killed; this WebView cannot be used any more.
            Logger.e { "ebook renderer gone, crash=${detail.didCrash()}" }
            if (webView === view) {
                binding.webContainer.removeView(view)
                view.destroy()
                webView = null
                showError(getString(MR.strings.ebook_cannot_open_title), "WebView renderer stopped")
            }
            return true
        }
    }

    // endregion

    // region Navigation

    private val spine get() = publication?.spine.orEmpty()

    private fun linearIndices(): List<Int> {
        val all = spine.indices.filter { spine[it].linear }
        return all.ifEmpty { spine.indices.toList() }
    }

    private fun firstLinear() = linearIndices().firstOrNull() ?: 0

    /** Opens the saved position, or the first document. */
    private fun openInitial() {
        val saved = restoreTarget
        restoreTarget = null
        if (saved != null) {
            // The path wins over the index, in case the book's spine changed.
            val index = spine.indexOfFirst { it.href == saved.href }.takeIf { it >= 0 } ?: saved.spine.takeIf { it in spine.indices }
            if (index != null) {
                openSpine(index, targetFor(saved))
                return
            }
        }
        openSpine(firstLinear(), START)
    }

    /** The shell's open target for a saved position (see reader.js start()). */
    private fun targetFor(saved: EbookLocator): String {
        val target = JSONObject()
        if (saved.location == null && saved.pageProgression != null) {
            target.put("pageProgression", saved.pageProgression)
        } else {
            saved.location?.let { target.put("location", JSONArray(it)) }
            if (saved.text.isNotEmpty()) target.put("text", saved.text)
            target.put("progression", saved.progression)
        }
        return target.toString()
    }

    private fun openSpine(index: Int, target: String) {
        val wv = webView ?: return
        val item = spine.getOrNull(index) ?: return
        spineIndex = index
        busy = true
        pendingRelayout = false
        val url = EbookRequestHandler.bookUrl(item.href)
        val json = settingsJson()
        appliedJson = json
        wv.evaluateJavascript("window.__reader.open(${JSONObject.quote(url)}, $json, $target)", null)
        awaitLayout()
    }

    /** Polls the shell until the current layout is finished, then shows the page. */
    private fun awaitLayout() {
        waitJob?.cancel()
        val progressAfter = SystemClock.uptimeMillis() + 300
        waitJob = lifecycleScope.launch {
            val deadline = SystemClock.uptimeMillis() + LAYOUT_TIMEOUT_MS
            while (true) {
                val status = eval("window.__reader.status()")?.let(::parseObject)
                if (status != null && status.optBoolean("ready")) {
                    binding.progress.isVisible = false
                    busy = false
                    val error = status.optString("error").takeIf { !status.isNull("error") && it.isNotEmpty() }
                    if (error != null) {
                        endPendingTurn()
                        showError(getString(MR.strings.ebook_cannot_open_title), error)
                    } else {
                        page = status.optInt("page")
                        pages = status.optInt("pages", 1)
                        columns = status.optInt("cols", 1)
                        readGutter(status)
                        updatePageInfo()
                        if (pendingRelayout) {
                            endPendingTurn()
                            pendingRelayout = false
                            applySettings()
                        } else {
                            capturePosition()
                            pendingTurn?.let {
                                pendingTurn = null
                                pendingTurnJob?.cancel()
                                playTurn(it)
                            }
                        }
                    }
                    return@launch
                }
                val now = SystemClock.uptimeMillis()
                if (now > progressAfter) binding.progress.isVisible = true
                if (now > deadline) {
                    busy = false
                    endPendingTurn()
                    binding.progress.isVisible = false
                    showError(getString(MR.strings.ebook_cannot_open_title), "Layout timed out")
                    return@launch
                }
                delay(POLL_MS)
            }
        }
    }

    private fun nextPage() = turnPage(forward = true)

    private fun previousPage() = turnPage(forward = false)

    /**
     * Turns the page, in the open document or into the next / previous one at its end. With a page turn
     * animation the page shown now is held on top (a copy, see [PageTurner]) while the shell moves on, then
     * slides or curls away: by the right edge for left-to-right pages, by the left edge for right-to-left
     * pages; with two columns one page turns about the centre line.
     */
    private fun turnPage(forward: Boolean) {
        if (busy) return
        lifecycleScope.launch {
            turnLock.withLock {
                if (busy) return@withLock
                turnJob?.cancel()
                val turner = pageTurner
                val style = turnStyle()
                if (style == null) turner?.end() // a turn still playing ends before the page changes again
                val held = turner != null && style != null && turner.hold()
                val turn = if (held && style != null) {
                    PageTurner.Turn(style, if (rtl) CurlEdge.LEFT else CurlEdge.RIGHT, columns == 2, forward, backgroundColor)
                } else {
                    null
                }
                val result = eval(if (forward) "window.__reader.next()" else "window.__reader.prev()")?.let(::parseString)
                when (result) {
                    "ok" -> {
                        refreshPage()
                        if (turn != null) playTurn(turn)
                    }
                    if (forward) "end" else "start" -> {
                        val target = if (forward) {
                            linearIndices().firstOrNull { it > spineIndex }
                        } else {
                            linearIndices().lastOrNull { it < spineIndex }
                        }
                        if (target != null) {
                            if (turn != null) holdUntilLaidOut(turn)
                            openSpine(target, if (forward) START else END)
                        } else {
                            turner?.end()
                            toast(getString(if (forward) MR.strings.ebook_end_of_book else MR.strings.ebook_start_of_book))
                        }
                    }
                    else -> turner?.end() // the shell is busy: the page did not change
                }
            }
        }
    }

    /** The page turn animation, or null to turn at once (also while the menu or the settings are shown). */
    private fun turnStyle(): PageTurner.Style? {
        if (menuVisible || panel != null || binding.errorPanel.isVisible || !ValueAnimator.areAnimatorsEnabled()) return null
        return when (pageTurnPreferences.textReader().get()) {
            PageTurnPreferences.SLIDE -> PageTurner.Style.SLIDE
            PageTurnPreferences.CURL -> PageTurner.Style.CURL
            else -> null
        }
    }

    /** Plays [turn] once the WebView has the new page ready to draw. */
    private fun playTurn(turn: PageTurner.Turn) {
        val turner = pageTurner ?: return
        turnJob = lifecycleScope.launch {
            awaitWebViewContent()
            turner.play(turn)
        }
    }

    /**
     * Keeps the old page on top while the next document is laid out, and plays [turn] when it is ready
     * ([awaitLayout]). A slow layout shows the reader (and its progress indicator) after a short while.
     */
    private fun holdUntilLaidOut(turn: PageTurner.Turn) {
        pendingTurn = turn
        pendingTurnJob?.cancel()
        pendingTurnJob = lifecycleScope.launch {
            delay(CROSS_DOCUMENT_HOLD_MS)
            if (pendingTurn === turn) endPendingTurn()
        }
    }

    private fun endPendingTurn() {
        if (pendingTurn == null) return
        pendingTurn = null
        pendingTurnJob?.cancel()
        pageTurner?.end()
    }

    private fun endTurn() {
        pendingTurn = null
        pendingTurnJob?.cancel()
        turnJob?.cancel()
        pageTurner?.end()
    }

    /** Waits until the WebView can draw what the shell shows now (or a short while). */
    private suspend fun awaitWebViewContent() {
        val wv = webView ?: return
        withTimeoutOrNull(VISUAL_STATE_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                wv.postVisualStateCallback(
                    0L,
                    object : WebView.VisualStateCallback() {
                        override fun onComplete(requestId: Long) {
                            if (cont.isActive) cont.resume(Unit)
                        }
                    },
                )
            }
        }
    }

    /**
     * Waits for the relayout the shell starts by itself after a viewport change (its layout counter `seq`
     * moves on), then updates the page indicator. The page's resize event can come seconds after the view
     * changed size (seen on a slow emulator), so the wait is long; if no new layout shows up within
     * [RESIZE_GRACE_MS], the current one is taken.
     */
    private fun refreshAfterResize() {
        resizeJob?.cancel()
        resizeJob = lifecycleScope.launch {
            val before = eval("window.__reader.status()")?.let(::parseObject)?.optInt("seq", -1) ?: -1
            val start = SystemClock.uptimeMillis()
            while (SystemClock.uptimeMillis() - start < LAYOUT_TIMEOUT_MS) {
                delay(RESIZE_POLL_MS)
                if (busy) continue // awaitLayout() updates the indicator when the layout it waits for is done
                val status = eval("window.__reader.status()")?.let(::parseObject) ?: continue
                if (!status.isNull("error")) return@launch // the error screen has no page indicator
                val relaidOut = status.optInt("seq", -1) != before
                if (status.optBoolean("ready") && (relaidOut || SystemClock.uptimeMillis() - start > RESIZE_GRACE_MS)) {
                    page = status.optInt("page")
                    pages = status.optInt("pages", 1)
                    columns = status.optInt("cols", 1)
                    readGutter(status)
                    updatePageInfo()
                    capturePosition()
                    return@launch
                }
            }
        }
    }

    private suspend fun refreshPage() {
        val status = eval("window.__reader.status()")?.let(::parseObject) ?: return
        page = status.optInt("page")
        pages = status.optInt("pages", 1)
        columns = status.optInt("cols", 1)
        readGutter(status)
        updatePageInfo()
        capturePosition()
    }

    /** Where the shell puts the gap between two columns (none with one column), then shows the shadow there. */
    private fun readGutter(status: JSONObject) {
        gutterCss = if (status.isNull("gutter")) null else status.optDouble("gutter").takeIf { it.isFinite() }
        showGutter()
        // The panel limits the side margins to what keeps two columns on this screen (stage 8).
        marginMost = if (status.optBoolean("twoWanted") && !status.isNull("marginMost")) {
            status.optInt("marginMost").takeIf { it >= 0 }
        } else {
            null
        }
        panel?.let { if (it.marginMost != marginMost) panel = it.copy(marginMost = marginMost) }
    }

    /**
     * The fold's shadow on the gap between the two columns, when there are two and the setting is on. A CSS px of
     * the page is a dp (as for the hit test of links).
     */
    private fun showGutter() {
        val view = gutterView ?: return
        val center = gutterCss
        val x = if (center != null && webView != null && gutterPreferences.textReader().get()) {
            (center * resources.displayMetrics.density).toFloat()
        } else {
            null
        }
        view.show(x)
    }

    /** Reads the position shown now from the shell and saves it shortly after (see [scheduleSave]). */
    private suspend fun capturePosition() {
        if (busy || session == null || binding.errorPanel.isVisible) return
        val pos = eval("window.__reader.position()")?.let(::parseObject) ?: return
        val index = spineIndex
        val item = spine.getOrNull(index) ?: return
        val location = pos.optJSONArray("location")?.let { listOf(it.getInt(0), it.getInt(1)) }
        val chars = pos.optInt("chars")
        val before = if (pos.isNull("before")) null else pos.optInt("before")
        val shownPage = pos.optInt("page")
        val docPages = pos.optInt("pages", 1).coerceAtLeast(1)
        val shownColumns = pos.optInt("cols", 1)
        val progression = if (location != null && before != null && chars > 0) (before.toDouble() / chars).coerceIn(0.0, 1.0) else 0.0
        val pageProgression = if (location == null) (shownPage.toDouble() / docPages).coerceIn(0.0, 1.0) else null
        val atEnd = shownPage + shownColumns > docPages - 1 && linearIndices().none { it > index }
        currentLocator = EbookLocator(
            spine = index,
            href = item.href,
            location = location,
            text = pos.optString("text"),
            progression = progression,
            pageProgression = pageProgression,
            total = if (atEnd) 1.0 else session?.progress?.total(index, pageProgression ?: progression),
            atEnd = atEnd,
            updatedAt = System.currentTimeMillis(),
        )
        currentDocPages = docPages
        currentPage = shownPage
        bookProgress = currentLocator?.total?.toFloat()
        scheduleSave()
    }

    /** Page turns come in bursts; the position is written once they stop. */
    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = lifecycleScope.launch {
            delay(SAVE_DELAY_MS)
            persistPosition()
        }
    }

    /**
     * Writes the current position, progress and read state. Runs outside the activity's scope so that
     * leaving the reader does not cancel it.
     */
    private fun persistPosition() {
        val save = positionWriter() ?: return
        launchIO { save() }
    }

    /** Saves the position shown now and returns once it is written (main thread). */
    private suspend fun writePosition() {
        saveJob?.cancel()
        val save = positionWriter() ?: return
        withIOContext { save() }
    }

    /** Takes the position shown now (main thread); the function returned writes it (see [ReadingSession.save]). */
    private fun positionWriter(): (suspend () -> Unit)? {
        val locator = currentLocator ?: return null
        val readingSession = session ?: return null
        val docPages = currentDocPages
        val shownPage = currentPage
        return {
            val errors = saveLock.withLock {
                runCatching { readingSession.save(locator, locator.spine, shownPage, docPages) }
                    .onFailure { Logger.e(it) { "Saving the reading position failed" } }
                    .getOrDefault(emptyList())
            }
            if (errors.isNotEmpty()) {
                withUIContext {
                    toast(getString(MR.strings.failed_to_update_, errors.joinToString(", ") { getString(it.first.nameRes()) }))
                }
            }
        }
    }

    // region Table of contents and progress slider

    /** A table of contents entry with its depth and the spine index of its target (null without a target). */
    private data class TocItem(val title: String, val href: String?, val depth: Int, val spine: Int?)

    private val tocItems: List<TocItem> by lazy {
        val items = ArrayList<TocItem>()
        fun add(entries: List<TocEntry>, depth: Int) {
            for (e in entries) {
                val target = e.href?.substringBefore('#')
                items += TocItem(e.title, e.href, depth, target?.let { t -> spine.indexOfFirst { it.href == t }.takeIf { it >= 0 } })
                if (depth < 8) add(e.children, depth + 1)
            }
        }
        add(publication?.toc.orEmpty(), 0)
        items
    }

    /** The chapter panel: the other chapters (files) of the work. */
    private fun showChapters() {
        val m = manga ?: return
        val c = chapter ?: return
        setMenuVisible(false)
        lifecycleScope.launch { ChapterPanel(this@EbookReaderActivity, m, c, ::openChapter).show() }
    }

    /** Opens [target] from the chapter panel, in the reader its file needs (ReaderActivity.newIntent). */
    private fun openChapter(target: Chapter) {
        val m = manga ?: return
        lifecycleScope.launch {
            writePosition() // this chapter's position is saved before the next one is read
            startActivity(ReaderActivity.newIntent(this@EbookReaderActivity, m, target).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION))
            finish()
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    private fun showToc() {
        val items = tocItems
        if (items.isEmpty()) {
            toast(getString(MR.strings.ebook_toc_empty))
            return
        }
        setMenuVisible(false)
        // The current entry: the last one that starts in or before the open document.
        val current = items.indexOfLast { it.spine != null && it.spine <= spineIndex }
        val labels = items.map { "\u3000".repeat(it.depth) + it.title }.toTypedArray()
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(MR.strings.ebook_toc))
            .setSingleChoiceItems(labels, current) { dialog, which ->
                dialog.dismiss()
                goToHref(items[which].href)
            }
            .setNegativeButton(getString(MR.strings.cancel), null)
            .show()
    }

    /** Opens a container path with an optional `#fragment` (a table of contents target). */
    private fun goToHref(href: String?) {
        if (href == null || busy) return
        val path = href.substringBefore('#')
        val fragment = href.substringAfter('#', "").ifEmpty { null }
        val index = spine.indexOfFirst { it.href == path }
        if (index < 0) {
            toast(getString(MR.strings.ebook_link_not_found))
            return
        }
        if (index != spineIndex) {
            openSpine(index, if (fragment == null) START else "{fragment: ${JSONObject.quote(fragment)}}")
            return
        }
        lifecycleScope.launch {
            val script = if (fragment == null) "window.__reader.goPage(0)" else "window.__reader.goFragment(${JSONObject.quote(fragment)})"
            if (eval(script) == "true") refreshPage() else toast(getString(MR.strings.ebook_link_not_found))
        }
    }

    /** The table of contents entry at a fraction of the book (the slider's label while dragging). */
    private fun tocTitleAt(fraction: Float): String? {
        val progress = session?.progress ?: return null
        val (index, _) = progress.locate(fraction.toDouble())
        return tocItems.lastOrNull { it.spine != null && it.spine <= index }?.title
    }

    /** Moves to a fraction of the whole book (the slider was released there). */
    private fun seekBook(fraction: Float) {
        val progress = session?.progress ?: return
        if (busy) return
        val (index, docFraction) = progress.locate(fraction.toDouble())
        if (index == spineIndex) {
            lifecycleScope.launch {
                if (eval("window.__reader.goProgress($docFraction)") == "true") refreshPage()
            }
        } else {
            openSpine(index, JSONObject().put("progression", docFraction).toString())
        }
    }

    // endregion

    private fun onLink(url: String) {
        val inBook = EbookRequestHandler.bookPathOf(url)
        if (inBook != null) {
            val (path, fragment) = inBook
            val index = spine.indexOfFirst { it.href == path }
            when {
                index < 0 -> toast(getString(MR.strings.ebook_link_not_found))
                index == spineIndex && fragment.isNullOrEmpty() -> Unit
                index == spineIndex -> lifecycleScope.launch {
                    if (eval("window.__reader.goFragment(${JSONObject.quote(fragment)})") == "true") {
                        refreshPage()
                    } else {
                        toast(getString(MR.strings.ebook_link_not_found))
                    }
                }
                else -> openSpine(index, if (fragment.isNullOrEmpty()) START else "{fragment: ${JSONObject.quote(fragment)}}")
            }
            return
        }
        val uri = Uri.parse(url)
        if (uri.scheme?.lowercase() !in EXTERNAL_SCHEMES) return
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(MR.strings.ebook_open_external_link))
            .setMessage(url)
            .setPositiveButton(getString(MR.strings.open_in_browser)) { _, _ ->
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                } catch (e: ActivityNotFoundException) {
                    toast(e.message)
                }
            }
            .setNegativeButton(getString(MR.strings.cancel), null)
            .show()
    }

    // endregion

    // region Input

    private inner class TouchListener : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true

        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            onTap(e.x, e.y)
            return true
        }

        override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
            val start = e1 ?: return false
            val dx = e2.x - start.x
            val dy = e2.y - start.y
            if (panel != null) return true
            if (abs(dx) < abs(dy) || abs(dx) < resources.displayMetrics.density * 48) return false
            // Swiping right brings in the page on the left, which comes next when pages turn right-to-left.
            val towardsLeftPage = dx > 0
            if (towardsLeftPage == rtl) nextPage() else previousPage()
            return true
        }
    }

    private fun onTap(x: Float, y: Float) {
        if (panel != null) {
            panel = null
            return
        }
        if (menuVisible) {
            setMenuVisible(false)
            return
        }
        val wv = webView
        if (wv == null || busy) {
            if (wv == null) setMenuVisible(true)
            return
        }
        val density = resources.displayMetrics.density
        lifecycleScope.launch {
            val link = eval("window.__reader.hit(${x / density}, ${y / density})")?.let(::parseString)
            if (!link.isNullOrEmpty()) {
                onLink(link)
                return@launch
            }
            val w = binding.root.width.coerceAtLeast(1).toFloat()
            val h = binding.root.height.coerceAtLeast(1).toFloat()
            when (navigation().getAction(PointF(x / w, y / h))) {
                ViewerNavigation.NavigationRegion.MENU -> setMenuVisible(true)
                ViewerNavigation.NavigationRegion.NEXT -> nextPage()
                ViewerNavigation.NavigationRegion.PREV -> previousPage()
                // Left and right follow the page direction: the next page is on the left when pages turn right to left.
                ViewerNavigation.NavigationRegion.LEFT -> if (rtl) nextPage() else previousPage()
                ViewerNavigation.NavigationRegion.RIGHT -> if (rtl) previousPage() else nextPage()
            }
        }
    }

    /**
     * Tap zones of the existing reader settings for paged viewers ("navigation layout" and "invert
     * tapping"), read at each tap so a change in the settings applies at once. The default is the
     * left / right thirds that the paged viewers use (RightAndLeftNavigation).
     */
    private fun navigation(): ViewerNavigation = when (preferences.navigationModePager().get()) {
        1 -> LNavigation()
        2 -> KindlishNavigation()
        3 -> EdgeNavigation()
        4 -> RightAndLeftNavigation()
        5 -> DisabledNavigation()
        else -> RightAndLeftNavigation()
    }.also { it.invertMode = preferences.pagerNavInverted().get() }

    /**
     * Page keys are handled before the view hierarchy: a focused WebView would otherwise consume
     * DPAD and PAGE keys. Volume keys turn pages only when the existing reader option is on.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val volumeKeys = preferences.readWithVolumeKeys().get()
        val inverted = preferences.readWithVolumeKeysInverted().get()
        val action: (() -> Unit)? = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> if (!volumeKeys) null else if (inverted) ::previousPage else ::nextPage
            KeyEvent.KEYCODE_VOLUME_UP -> if (!volumeKeys) null else if (inverted) ::nextPage else ::previousPage
            KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_SPACE -> ::nextPage
            KeyEvent.KEYCODE_PAGE_UP -> ::previousPage
            KeyEvent.KEYCODE_DPAD_LEFT -> if (rtl) ::nextPage else ::previousPage
            KeyEvent.KEYCODE_DPAD_RIGHT -> if (rtl) ::previousPage else ::nextPage
            else -> null
        }
        if (action == null || menuVisible || panel != null || binding.errorPanel.isVisible) {
            return super.dispatchKeyEvent(event)
        }
        if (event.action == KeyEvent.ACTION_DOWN) action()
        return true
    }

    // endregion

    // region UI

    private fun setMenuVisible(visible: Boolean) {
        if (visible) endTurn() // the turn is drawn above the window, so it would cover the menu
        menuVisible = visible
        binding.toolbar.isVisible = visible
        barVisible = visible && webView != null && publication != null && !binding.errorPanel.isVisible
        applySystemBars()
        // The shell re-lays out by itself after rotation (pages and columns change), so read them again.
        if (barVisible && !busy) lifecycleScope.launch { refreshPage() }
    }

    private fun applySystemBars() {
        if (menuVisible || !preferences.fullscreen().get()) {
            insetsController.show(WindowInsetsCompat.Type.systemBars())
        } else {
            insetsController.hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    private fun updatePageInfo() {
        // Two columns: both pages of the spread, e.g. "3–4/35" (the last spread can hold one page).
        val shown = if (columns > 1 && page + 2 <= pages) "${page + 1}–${page + 2}" else "${page + 1}"
        pageInfoText = "${spineIndex + 1}/${spine.size} · $shown/$pages"
    }

    private fun showError(error: Throwable) {
        Logger.e(error) { "Cannot open book" }
        when (error) {
            is DrmProtectedException -> showError(
                getString(MR.strings.ebook_drm_title),
                getString(MR.strings.ebook_drm_message, error.scheme),
            )
            is UnsupportedBookException -> showError(
                getString(MR.strings.ebook_cannot_open_title),
                if (error.message.orEmpty().contains("KFX")) getString(MR.strings.ebook_kfx_message) else error.message.orEmpty(),
            )
            is CorruptBookException -> showError(
                getString(MR.strings.ebook_cannot_open_title),
                getString(MR.strings.ebook_corrupt_message),
            )
            else -> showError(
                getString(MR.strings.ebook_cannot_open_title),
                error.message ?: getString(MR.strings.ebook_corrupt_message),
            )
        }
    }

    private fun showError(title: String, message: String) {
        endTurn()
        panel = null
        binding.toolbar.menu.findItem(MENU_SETTINGS)?.isVisible = false
        binding.toolbar.menu.findItem(MENU_TOC)?.isVisible = false
        binding.progress.isVisible = false
        binding.errorTitle.text = title
        binding.errorMessage.text = message
        binding.errorPanel.isVisible = true
        binding.webContainer.isVisible = false
        binding.touchLayer.isVisible = false
        setMenuVisible(true)
    }

    /** Background and text colours from the existing reader background setting. */
    private fun resolveColors() {
        val themeBackground = getResourceColor(R.attr.background)
        val themeText = getResourceColor(R.attr.colorOnBackground)
        when (ReaderBackgroundColor.fromPreference(preferences.readerTheme().get())) {
            ReaderBackgroundColor.WHITE -> {
                backgroundColor = Color.WHITE
                textColor = Color.BLACK
            }
            ReaderBackgroundColor.BLACK -> {
                backgroundColor = Color.BLACK
                textColor = Color.rgb(0xE0, 0xE0, 0xE0)
            }
            ReaderBackgroundColor.GRAY -> {
                backgroundColor = Color.rgb(32, 33, 37)
                textColor = Color.rgb(0xE0, 0xE0, 0xE0)
            }
            else -> {
                backgroundColor = themeBackground
                textColor = themeText
            }
        }
    }

    /** What the shell lays out with; "依書籍" values are null, so the book's own styles stay. */
    private fun settingsJson(): String {
        val s = settings
        val dark = ColorUtils.calculateLuminance(backgroundColor) < 0.5
        val font: Any = when (s.font) {
            EbookSettings.FONT_SANS, EbookSettings.FONT_SERIF -> JSONObject().put("kind", s.font)
            EbookSettings.FONT_BOOK -> JSONObject.NULL
            // A font that was deleted (or not restored with a backup) falls back to the book's.
            else -> fontStore.find(s.font)
                ?.let { JSONObject().put("kind", "imported").put("url", EbookRequestHandler.fontUrl(it.id)) }
                ?: JSONObject.NULL
        }
        return JSONObject()
            .put("vertical", vertical)
            // Which side the first page of a two-column spread goes on; the shell decides when to use two columns.
            .put("rtl", rtl)
            .put("columns", s.columns)
            .put("font", font)
            .put("bold", s.bold)
            .put("fontSize", s.fontSize)
            .put("lineHeight", cssNumber(s.lineHeight))
            .put("letterSpacing", cssNumber(s.letterSpacing))
            .put("indent", s.indent?.let(::cssNumber) ?: JSONObject.NULL)
            .put("paragraphSpacing", s.paragraphSpacing?.let(::cssNumber) ?: JSONObject.NULL)
            .put(
                "margins",
                JSONObject()
                    .put("top", s.marginTop)
                    .put("bottom", s.marginBottom)
                    .put("left", s.marginLeft)
                    .put("right", s.marginRight),
            )
            .put("background", cssColor(backgroundColor))
            .put("textColor", cssColor(textColor))
            .put("dark", dark)
            .toString()
    }

    /** 1.8f as 1.8 rather than 1.7999999523. */
    private fun cssNumber(value: Float): Double = EbookSettings.format(value).toDouble()

    private fun cssColor(color: Int) = String.format(Locale.ROOT, "#%06X", 0xFFFFFF and color)

    // endregion

    // region Settings

    private fun resolveMode() {
        vertical = when (settings.writingMode) {
            EbookSettings.MODE_VERTICAL -> true
            EbookSettings.MODE_HORIZONTAL -> false
            else -> bookVertical
        }
        rtl = settings.rightToLeft(vertical)
        rtlState = rtl
    }

    private fun openSettings() {
        val key = bookKey ?: return
        endTurn()
        setMenuVisible(false)
        showPanel(settingsStore.initialScope(key))
    }

    /** Shows (or refreshes) the panel for [scope]. */
    private fun showPanel(scope: SettingsScope) {
        val key = bookKey ?: return
        panel = EbookSettingsUiState(
            settings = settingsStore.resolvedAt(scope, key),
            scope = scope,
            scopeHasValues = settingsStore.levelValues(scope, key).isNotEmpty(),
            overridden = settingsStore.overriddenBelow(scope, key),
            fonts = fontStore.list(),
            pageTurn = pageTurnPreferences.textReader().get(),
            gutterShadow = gutterPreferences.textReader().get(),
            marginMost = marginMost,
        )
    }

    /** The fold's shadow is one setting for all books, outside the three levels (stage 7). */
    private fun onGutterShadowChanged(value: Boolean) {
        gutterPreferences.textReader().set(value)
        panel = panel?.copy(gutterShadow = value)
        showGutter()
    }

    /** The page turn animation is one setting for all books, outside the three levels. */
    private fun onPageTurnChanged(value: String) {
        pageTurnPreferences.textReader().set(value)
        panel = panel?.copy(pageTurn = value)
    }

    private fun onSettingChanged(key: EbookSettings.Key, value: String) {
        val book = bookKey ?: return
        val scope = panel?.scope ?: return
        settingsStore.set(scope, book, key, value)
        refreshSettings()
    }

    private fun resetScope() {
        val book = bookKey ?: return
        val scope = panel?.scope ?: return
        settingsStore.clear(scope, book)
        refreshSettings()
    }

    /** Re-reads the effective settings after a change and applies them to the page. */
    private fun refreshSettings() {
        val book = bookKey ?: return
        settings = settingsStore.effective(book)
        resolveMode()
        panel?.let { showPanel(it.scope) }
        applySettings()
    }

    /** Re-lays out the open document if what the shell uses changed; it returns to the same character. */
    private fun applySettings() {
        if (webView == null || !shellLoaded || binding.errorPanel.isVisible) return
        endTurn()
        val json = settingsJson()
        if (json == appliedJson) return
        if (busy) {
            pendingRelayout = true
            return
        }
        busy = true
        lifecycleScope.launch {
            if (eval("window.__reader.relayout($json)") == "true") {
                appliedJson = json
                awaitLayout()
            } else {
                busy = false
            }
        }
    }

    private fun importFont() {
        try {
            // Font files often have no specific MIME type on the device; the content is checked instead.
            fontPicker.launch(arrayOf("*/*"))
        } catch (e: ActivityNotFoundException) {
            toast(e.message)
        }
    }

    private fun onFontPicked(uri: Uri) {
        lifecycleScope.launch {
            val pending = withIOContext { runCatching { fontStore.read(uri) } }.getOrElse {
                Logger.w(it) { "Font import failed" }
                toast(getString(MR.strings.ebook_font_invalid))
                return@launch
            }
            if (pending.info.supportsVertical) {
                saveFont(pending)
                return@launch
            }
            val missing = buildList {
                if (!pending.info.hasVerticalMetrics) add("vhea/vmtx")
                if (!pending.info.hasVerticalGlyphs) add("vert/vrt2")
            }.joinToString(", ")
            MaterialAlertDialogBuilder(this@EbookReaderActivity)
                .setTitle(pending.name)
                .setMessage(getString(MR.strings.ebook_font_no_vertical, missing))
                .setPositiveButton(getString(MR.strings.ebook_font_import_action)) { _, _ -> saveFont(pending) }
                .setNegativeButton(getString(MR.strings.cancel), null)
                .show()
        }
    }

    private fun saveFont(pending: FontStore.Pending) {
        lifecycleScope.launch {
            val saved = withIOContext { runCatching { fontStore.save(pending) } }.getOrElse {
                Logger.e(it) { "Saving font failed" }
                toast(it.message)
                return@launch
            }
            toast(getString(MR.strings.ebook_font_imported, saved.name))
            panel?.let { showPanel(it.scope) }
        }
    }

    private fun confirmDeleteFont(font: ImportedFont) {
        MaterialAlertDialogBuilder(this)
            .setMessage(getString(MR.strings.ebook_font_delete_confirm, font.name))
            .setPositiveButton(getString(MR.strings.delete)) { _, _ ->
                fontStore.delete(font.id)
                refreshSettings()
            }
            .setNegativeButton(getString(MR.strings.cancel), null)
            .show()
    }

    // endregion

    // region JavaScript bridge (native → shell only)

    private suspend fun eval(script: String): String? {
        val wv = webView ?: return null
        return suspendCancellableCoroutine { cont ->
            wv.evaluateJavascript(script) { result -> if (cont.isActive) cont.resume(result) }
        }
    }

    private fun parseObject(json: String): JSONObject? = runCatching { JSONTokener(json).nextValue() as? JSONObject }.getOrNull()

    private fun parseString(json: String): String? = runCatching { JSONTokener(json).nextValue() as? String }.getOrNull()

    // endregion

    companion object {
        private const val EXTRA_MANGA = "manga"
        private const val EXTRA_CHAPTER = "chapter"

        /** Set when the user switched this chapter from the image reader ("open as text"). */
        const val EXTRA_SWITCHED_FROM_IMAGES = "switched_from_images"

        private const val START = "'start'"
        private const val END = "'end'"
        private const val POLL_MS = 40L
        private const val SAVE_DELAY_MS = 1_000L
        private const val RESIZE_POLL_MS = 200L
        private const val RESIZE_GRACE_MS = 15_000L
        private const val LAYOUT_TIMEOUT_MS = 60_000L
        /** How long the old page stays on top while the next document is laid out. */
        private const val CROSS_DOCUMENT_HOLD_MS = 700L
        private const val VISUAL_STATE_TIMEOUT_MS = 500L

        private const val MENU_SETTINGS = 1
        private const val MENU_TOC = 2
        private const val MENU_OPEN_AS_IMAGES = 3
        private const val MENU_CHAPTERS = 4

        private val EXTERNAL_SCHEMES = setOf("http", "https", "mailto")

        fun newIntent(context: Context, manga: Manga, chapter: Chapter): Intent =
            newIntent(context, manga.id!!, chapter.id!!)

        fun newIntent(context: Context, mangaId: Long, chapterId: Long): Intent =
            Intent(context, EbookReaderActivity::class.java)
                .putExtra(EXTRA_MANGA, mangaId)
                .putExtra(EXTRA_CHAPTER, chapterId)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
}
