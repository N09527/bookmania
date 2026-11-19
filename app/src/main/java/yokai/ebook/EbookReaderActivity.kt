package yokai.ebook

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.TypedValue
import android.view.GestureDetector
import android.view.Gravity
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.data.database.models.Chapter
import eu.kanade.tachiyomi.databinding.EbookReaderActivityBinding
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import eu.kanade.tachiyomi.source.SourceManager
import eu.kanade.tachiyomi.ui.base.activity.BaseActivity
import eu.kanade.tachiyomi.ui.reader.settings.ReaderBackgroundColor
import eu.kanade.tachiyomi.util.system.getResourceColor
import eu.kanade.tachiyomi.util.system.toast
import eu.kanade.tachiyomi.util.system.withIOContext
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.math.abs
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import org.json.JSONTokener
import uy.kohesive.injekt.injectLazy
import yokai.core.ebook.CorruptBookException
import yokai.core.ebook.DrmProtectedException
import yokai.core.ebook.Publication
import yokai.core.ebook.UnsupportedBookException
import yokai.core.ebook.WritingModeHint
import yokai.domain.chapter.interactor.GetChapter
import yokai.domain.manga.interactor.GetManga
import yokai.ebook.settings.BookKey
import yokai.ebook.settings.EbookSettings
import yokai.ebook.settings.EbookSettingsPanel
import yokai.ebook.settings.EbookSettingsStore
import yokai.ebook.settings.EbookSettingsUiState
import yokai.ebook.settings.FontStore
import yokai.ebook.settings.ImportedFont
import yokai.ebook.settings.SettingsScope
import yokai.i18n.MR
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

    private val requestHandler by lazy { EbookRequestHandler(assets) }
    private val settingsStore by lazy { EbookSettingsStore(preferences.preferenceStore) }
    private val fontStore by lazy { FontStore(this, preferences.preferenceStore) }
    private var webView: WebView? = null
    private var shellLoaded = false

    private var publication: Publication? = null
    private var manga: Manga? = null
    private var chapter: Chapter? = null
    private var spineIndex = 0
    private var bookKey: BookKey? = null
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

    private var busy = false
    private var waitJob: Job? = null
    private var menuVisible = false
    private lateinit var gestures: GestureDetector
    private lateinit var insetsController: WindowInsetsControllerCompat

    private var backgroundColor = Color.WHITE
    private var textColor = Color.BLACK

    /** The settings panel, or null when it is closed. */
    private var panel by mutableStateOf<EbookSettingsUiState?>(null)
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
        ViewCompat.setOnApplyWindowInsetsListener(binding.toolbar) { v, insets ->
            val top = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top
            v.updatePadding(top = top)
            v.minimumHeight = actionBarSize + top
            insets
        }
        val pageInfoMargin = (binding.pageInfo.layoutParams as ViewGroup.MarginLayoutParams).bottomMargin
        ViewCompat.setOnApplyWindowInsetsListener(binding.pageInfo) { v, insets ->
            v.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                bottomMargin = pageInfoMargin + insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
            }
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
        binding.toolbar.menu.add(Menu.NONE, MENU_SETTINGS, Menu.NONE, getString(MR.strings.ebook_settings)).apply {
            setIcon(R.drawable.ic_tune_24dp)
            iconTintList = ColorStateList.valueOf(getResourceColor(R.attr.colorOnSurface))
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            isVisible = false // until a book is open
        }
        binding.toolbar.setOnMenuItemClickListener { item ->
            if (item.itemId == MENU_SETTINGS) openSettings()
            item.itemId == MENU_SETTINGS
        }
        binding.root.addView(
            ComposeView(this).apply {
                layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM)
                elevation = resources.displayMetrics.density * 16 // above the toolbar and the page number
                setContent {
                    YokaiTheme {
                        panel?.let { state ->
                            EbookSettingsPanel(
                                state = state,
                                onScopeChange = ::showPanel,
                                onSet = ::onSettingChanged,
                                onResetScope = ::resetScope,
                                onImportFont = ::importFont,
                                onDeleteFont = ::confirmDeleteFont,
                                onClose = { panel = null },
                            )
                        }
                    }
                }
            },
        )
        requestHandler.fontFile = { id -> fontStore.file(id) }

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

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Re-apply after dialogs and when the window is first shown (hiding in onCreate is not
        // always honoured on older Android versions).
        if (hasFocus) applySystemBars()
    }

    override fun onDestroy() {
        waitJob?.cancel()
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
                Triple(manga, chapter, LocalEbooks.open(file, this@EbookReaderActivity))
            }
        }
        if (isDestroyed) {
            result.getOrNull()?.third?.close()
            return
        }
        binding.progress.isVisible = false
        val (manga, chapter, pub) = result.getOrElse {
            showError(it)
            return
        }
        this.manga = manga
        this.chapter = chapter
        publication = pub
        if (pub.spine.isEmpty()) {
            showError(getString(MR.strings.ebook_cannot_open_title), getString(MR.strings.ebook_no_content))
            return
        }
        val key = BookKey(manga.source, manga.url, chapter.url)
        bookKey = key
        settings = settingsStore.effective(key)
        bookVertical = pub.writingModeHint == WritingModeHint.VERTICAL
        resolveMode()
        binding.toolbar.title = pub.metadata.title ?: chapter.name
        binding.toolbar.subtitle = manga.title
        binding.toolbar.menu.findItem(MENU_SETTINGS)?.isVisible = true
        requestHandler.publication = pub
        createWebView()
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
        binding.webContainer.addView(wv)
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
                openSpine(firstLinear(), START)
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
                        showError(getString(MR.strings.ebook_cannot_open_title), error)
                    } else {
                        page = status.optInt("page")
                        pages = status.optInt("pages", 1)
                        updatePageInfo()
                        if (pendingRelayout) {
                            pendingRelayout = false
                            applySettings()
                        }
                    }
                    return@launch
                }
                val now = SystemClock.uptimeMillis()
                if (now > progressAfter) binding.progress.isVisible = true
                if (now > deadline) {
                    busy = false
                    binding.progress.isVisible = false
                    showError(getString(MR.strings.ebook_cannot_open_title), "Layout timed out")
                    return@launch
                }
                delay(POLL_MS)
            }
        }
    }

    private fun nextPage() {
        if (busy) return
        lifecycleScope.launch {
            when (eval("window.__reader.next()")?.let(::parseString)) {
                "ok" -> refreshPage()
                "end" -> {
                    val next = linearIndices().firstOrNull { it > spineIndex }
                    if (next != null) openSpine(next, START) else toast(getString(MR.strings.ebook_end_of_book))
                }
            }
        }
    }

    private fun previousPage() {
        if (busy) return
        lifecycleScope.launch {
            when (eval("window.__reader.prev()")?.let(::parseString)) {
                "ok" -> refreshPage()
                "start" -> {
                    val previous = linearIndices().lastOrNull { it < spineIndex }
                    if (previous != null) openSpine(previous, END) else toast(getString(MR.strings.ebook_start_of_book))
                }
            }
        }
    }

    private suspend fun refreshPage() {
        val status = eval("window.__reader.status()")?.let(::parseObject) ?: return
        page = status.optInt("page")
        pages = status.optInt("pages", 1)
        updatePageInfo()
    }

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
            val third = binding.root.width / 3f
            when {
                x < third -> if (rtl) nextPage() else previousPage()
                x > third * 2 -> if (rtl) previousPage() else nextPage()
                else -> setMenuVisible(true)
            }
        }
    }

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
        menuVisible = visible
        binding.toolbar.isVisible = visible
        binding.pageInfo.isVisible = visible && webView != null && publication != null
        applySystemBars()
    }

    private fun applySystemBars() {
        if (menuVisible || !preferences.fullscreen().get()) {
            insetsController.show(WindowInsetsCompat.Type.systemBars())
        } else {
            insetsController.hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    private fun updatePageInfo() {
        binding.pageInfo.text = "${spineIndex + 1}/${spine.size} · ${page + 1}/$pages"
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
        panel = null
        binding.toolbar.menu.findItem(MENU_SETTINGS)?.isVisible = false
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
            .put("font", font)
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
    }

    private fun openSettings() {
        val key = bookKey ?: return
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
        )
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

        private const val START = "'start'"
        private const val END = "'end'"
        private const val POLL_MS = 40L
        private const val LAYOUT_TIMEOUT_MS = 60_000L

        private const val MENU_SETTINGS = 1

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
