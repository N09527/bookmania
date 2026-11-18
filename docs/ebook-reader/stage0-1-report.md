# Yokai 文字型電子書閱讀：階段 0／1 報告與設計提案

- 日期：2026-11-16
- 基準：https://github.com/null2264/yokai `master` @ `843a59b`（2026-09-28）
- 狀態：**設計提案，等待確認**。依任務文件第 7 節，確認前不做大規模實作。目前沒有修改 Yokai 任何既有檔案，只新增了本目錄 `docs/ebook-reader/`（原型、截圖、本文件），尚未 commit。

標示沿用任務文件：【已查證】＝本次實際讀原始碼／文件或實測；【推論】＝由事實推導、未實測；【建議】＝我的提案，等你決定。

---

## 0. 摘要

1. **階段 0 完成**：未修改的原始碼可以建置（`assembleStandardRelease`，12 分 19 秒），上游 CI 的單元測試 54 個全部通過。此環境沒有硬體虛擬化，但 Android 模擬器能以純軟體模式開機，可做功能驗證，不能做效能量測。
2. **2.3 第 10 項（直書＋雙欄必須左右排列）可以做到**。原型在桌面 Chromium 153 做出「左右雙欄、右欄先讀」，逐字比對確認翻遍整章時每個字恰好出現一次、沒有被裁切的字。在 Android 8.0 模擬器（WebView 69，不支援 `column-wrap`）上，做法 B 同樣通過（258 個邊界檢查 0 失敗），做法 A 則失敗（925 字跨欄），證實需要「偵測後改用 B」。另發現舊版 WebView 會把位於頁首行的注音畫到前一頁（4.5 第 6 點）。詳見第 4 節。
3. **建議方案**：用 Kotlin 解析 EPUB／MOBI／AZW3，經 App 內的虛擬網域交給 WebView，由自寫的分頁殼層排版（不使用 Readium 或 foliate-js 的分頁器）。直書雙欄以「雙 iframe（做法 B）」為基準實作，WebView 支援 `column-wrap` 時改用只排版一次的做法 A。執行期不新增第三方函式庫。
4. **需要你決定的事項**在第 7 節：任務文件的 11 題，加上我新增的 3 題。

---

## 1. 階段 0：基線

### 1.1 環境【已查證】

| 項目 | 值 |
|---|---|
| 作業系統 | Ubuntu 24.04.5 LTS（雲端 VM，4 vCPU、15 GB RAM） |
| JDK | OpenJDK 21.0.12（上游 CI 也用 JDK 21） |
| Android SDK（本次安裝） | cmdline-tools 19.0（SHA-1 與 Google 官方清單一致）、platforms;android-36、build-tools;35.0.0（與上游 CI 相同）、platform-tools、emulator 37.2.13 |
| 硬體虛擬化 | 沒有 `/dev/kvm`，CPU 未提供 vmx/svm。`emulator -accel-check` 回報 `accel: 3`、「KVM requires a CPU that supports vmx or svm」 |

### 1.2 為了在此環境建置所做的「環境層級」調整【已查證】

這些設定只在本機 `~/.gradle/`，**專案檔案沒有改動**（`git status` 乾淨）。

- Maven Central（`repo1.maven.org`、`repo.maven.apache.org`）對此環境回應 HTTP 429。回應標頭顯示來自 Cloudflare（`server: cloudflare`），不是本機代理。Gradle Plugin Portal 也會把部分請求轉址到 Maven Central。
- 處理方式：`~/.gradle/init.d/maven-central-mirror.gradle` 把 Maven Central 換成 Google 的鏡像 `maven-central.storage-download.googleapis.com`，並讓外掛解析先查鏡像與 Google Maven；另在 `~/.gradle/gradle.properties` 提高下載重試次數。
- 你的電腦或 GitHub Actions 若沒有 429 問題，不需要這些設定。

### 1.3 建置【已查證】

```
./gradlew assembleStandardRelease -x :app:uploadCrashlyticsMappingFileStandardRelease
```

- 結果：`BUILD SUCCESSFUL in 12m 19s`，211 個任務。
- 產物（未簽章）：`app/build/outputs/apk/standard/release/app-standard-{arm64-v8a, armeabi-v7a, x86, x86_64, universal}-release-unsigned.apk`（universal 68.5 MB、arm64-v8a 28.8 MB）。
- 為什麼排除 `uploadCrashlyticsMappingFileStandardRelease`：`--dry-run` 顯示 `assembleStandardRelease` 包含這個任務。它會把 R8 mapping 檔上傳到 `app/src/standard/google-services.json` 所指的上游 Firebase 專案（`yokai-4034e`）。排除它不影響 APK 內容，也避免從測試環境送資料給上游。

### 1.4 單元測試【已查證】

```
./gradlew testReleaseUnitTest testStandardReleaseUnitTest
```

- 結果：`BUILD SUCCESSFUL in 44s`。JUnit 報告共 54 個測試：失敗 0、錯誤 0、略過 0（`:app` 20 個、`:domain` 34 個）。

### 1.5 模擬器與實機【已查證】

- 沒有 KVM，但模擬器能以純軟體模式（`-accel off`）開機：
  - `system-images;android-26;default;x86_64`：130 秒開機。**但這個映像無法使用 WebView**：框架設定（`config_webview_packages.xml`）只接受 Google 簽章的提供者（`com.android.chrome`、`com.google.android.webview` 等），映像內建的 `com.android.webview` 58.0.3029.125 不在清單中，建立 WebView 時會因「No WebView installed」當機（實測 `org.chromium.webview_shell` 當機）。
  - `system-images;android-26;google_apis;x86_64`：195 秒開機，WebView 提供者是 **Chrome 69.0.3497.100**。第 4 節的 Android 驗證都在這個映像上做。
- 純軟體模擬很慢（qemu 約 100% CPU），可以驗證功能與排版，**效能數字沒有參考價值**。驗收第 9 項（開啟時間）必須在實機量測。
- 做不到的：實機測試；`column-wrap`（做法 A）在 Android WebView 上的驗證（需要 WebView 145 以上；映像內建版本都更舊，也無法登入 Play 商店更新）。
- **基線 APK 安裝與啟動**【已查證】：把 `app-standard-x86_64-release-unsigned.apk` 以本機產生的 debug 金鑰簽章（`apksigner verify` 通過；套件 `eu.kanade.tachiyomi.yokai`、versionCode 162、versionName 1.10.3），在 Android 8.0（google_apis 映像）上安裝成功，啟動後顯示首次使用的「Welcome!」畫面（`screenshots/android8-baseline-yokai-welcome.png`），logcat 沒有 `FATAL EXCEPTION`。
  - 測試前先開啟飛航模式，因為這是上游設定的版本：logcat 顯示它啟動時就初始化 FirebaseApp、Crashlytics 19.4.3 與 Firebase Sessions。這也印證 5.10 節「fork 必須拿掉 Google Services 外掛」的必要性。
  - 啟動過程出現一次 ANR，原因是 Firebase Sessions 的 `SessionLifecycleService` 執行逾時，當時系統負載 6.12。【推論】這是純軟體模擬太慢所致（同一時期系統介面也多次 ANR），不代表 App 本身有問題；按「等待」後畫面正常。

---

## 2. 第 3 節「專案現況」複核

### 2.1 與任務文件一致【已查證】

第 3.1、3.2 節的每一項我都對照 `843a59b` 原始碼確認過，全部一致：版本號、applicationId 與後綴、flavor 行為、SDK 與工具版本、ABI 與 split、CI 指令、8 個 Gradle 模組、Local Source 的資料結構與 `Format`、`EpubReader.getImagesFromPages()` 只取圖片、`ChapterLoader` 的 `no_pages_found`、Kotlin 原始碼中沒有任何 MOBI／AZW 處理、閱讀器 viewer 結構、`last_page_read`／`pages_left`、設定類別的位置、備份 protobuf、Manifest 沒有開啟檔案的 intent-filter、README 的「Requires Android 8.0 or higher」。

### 2.2 文件沒提到、但會影響設計的事實【已查證】

1. `chapters` 表有 `memo TEXT NOT NULL DEFAULT '{}'` 欄位，但它屬於擴充來源（註解寫「Matches Mihon for extension-lib 1.6 memo」），章節同步時會被來源的值覆寫（`ChapterSourceSync.kt:117`）。**不能**拿來存文字書的閱讀位置。
2. App 的偏好設定除了鍵名以 `__APP_STATE_`、`__PRIVATE_` 開頭的以外，會全部寫進備份（`PreferenceBackupCreator.kt`）。新增的排版設定會自動進備份；匯入字型的本機路徑不應該進備份。
3. `ReaderActivity.newIntent(...)` 在 6 個檔案被呼叫（書庫、作品詳情、最近閱讀、搜尋、主畫面、通知）。
4. 可重用的既有程式：追蹤更新 `eu.kanade.tachiyomi.util.chapter.updateTrackChapterRead(...)`；點擊區域 `ui/reader/viewer/navigation/` 下 5 種 `ViewerNavigation`；閱讀器設定 `readWithVolumeKeys`、`readWithVolumeKeysInverted`、`navigationModePager`、`pagerNavInverted`、`readerTheme`、`fullscreen`、`keepScreenOn`。
5. Firebase：`App.kt:129-136` 與 `CrashlyticsLogWriter.kt` 的 Firebase 呼叫都包在 try/catch 中。【推論】不套用 Google Services 外掛時 Firebase 不會初始化，也不會因此當機（需在模擬器確認）。上游 Firebase 專案只登錄了 `debugYokai`、`nightlyYokai`、`yokai` 三個套件名稱，fork 若換 applicationId，`standard` flavor 的 Google Services 外掛會在建置時找不到對應設定。
6. `standard` flavor 的 `INCLUDE_UPDATER=true` 會檢查 `null2264/yokai` 的 GitHub releases（`AppUpdateChecker.kt`），fork 若保留會提示下載上游版本。
7. `dev` flavor 只打包英文資源。若 fork 改用 `dev` flavor 來避開 Firebase，中文介面會消失，不可行。

---

## 3. 第 4 節外部資料複核

| 任務文件的說法 | 結果 | 依據 |
|---|---|---|
| Readium CSS 文件說直排只能單欄、多欄會上下堆疊，並指出實作者可自行實作直排分頁 | 一致 | `readium/readium-css` master 的 `docs/CSS03-injection_and_pagination.md`「The pagination model for vertical writing modes」節原文 |
| Readium Kotlin Toolkit 格式表沒有 MOBI／AZW3；3.4.0 需 compile SDK 37 | 一致；另外 3.2.0 需 compile SDK 36 | `readium/kotlin-toolkit` main 的 README |
| Readium 的邊距只有一個 `pageMargins` | 一致（0.0–4.0，步進 0.3） | `EpubPreferencesEditor.kt` 原始碼 |
| foliate-js 支援 EPUB、MOBI、KF8；API 不穩定；必須用 CSP 擋腳本 | 一致。README 另說明：因 WebKit bug 218086，iframe 必須加 `allow-scripts`，sandbox 因此失效（這是 WebKit 的問題） | foliate-js README |
| foliate-js 直排時沿高度方向切欄，只會得到單欄或上下欄 | 一致：`paginator.js` 的 `columnize()` 直排時固定 `width`，以 `column-width` 沿 y 軸切欄。我只讀了原始碼，未執行 | foliate-js 原始碼 |
| libmobi 為 LGPL-3.0-or-later，可解析 KF8（azw、azw3） | 一致 | libmobi README、COPYING |
| `column-wrap` 自 Chrome 145 | 一致：Chrome 開發者部落格原文（2026-01-14）「From Chrome 145, the column-wrap and column-height properties … are supported」；MDN browser-compat-data 8.1.9 中 Chrome 與 Android WebView 都是 145。Intent to Ship 列 144，我只看到搜尋摘要，沒讀到原文 | 部落格原文、BCD |
| Chrome 138 是最後支援 Android 8／9 的版本 | 一致：chromium-dev 公告（2025-06-19）原文「Chrome version 138 is the last release that will support Android Oreo and Android Pie … Version 139 is the first release which sets the minimum Android SDK version to Android 10 (API level 29)」。公告原文沒有出現 WebView 字樣，所以「Android 8／9 的 WebView 也停在 138」仍是**推論** | 公告原文 |

---

## 4. 直書左右雙欄原型

### 4.1 原型內容

- 測試書：自撰的繁體中文直排章節（`lang="zh-Hant"`，120 段、5,829 個非空白字元）。內含「」『』（）、全形標點、……、——、英文 WebView、半形數字、全形數字、注音 ruby、縱中橫（12、31）、一張 SVG 插圖。另刻意放入安全測試：書內 `<script>`、`onerror` 屬性、外部圖片、外部連結、書內註腳連結。產生器：`prototype/gen_book.py`。
- 殼層：`prototype/reader/reader.html`、`reader.js`。書籍文件放在 `sandbox="allow-same-origin"`（不含 `allow-scripts`）的 iframe 中；iframe 設 `pointer-events: none`，觸控一律由外層處理；殼層從外部注入排版 CSS、控制翻頁。
- 三種模式：
  - **A**：`writing-mode: vertical-rl` ＋ `column-wrap: wrap` ＋ `column-height: <欄寬>`，單一 iframe。
  - **B**：兩個並排的 iframe 載入同一份文件，各自用傳統直排分頁（欄高＝頁高、沿 y 軸）；右框顯示第 2k 頁，左框顯示第 2k+1 頁。
  - **H**：橫書，一般 CSS 多欄。
- 字型：從 Ubuntu 套件 `fonts-noto-cjk`（SIL OFL）抽出 Noto Serif CJK TC 成單一 OTF 檔，以 `@font-face` 載入，模擬「使用者匯入的字型」。
- Android 驗證用的測試 App：`prototype/probe-app/`（只供驗證，不會出貨）。它模擬正式版的設計：以 `shouldInterceptRequest` 提供虛擬網域 `https://appassets.androidplatform.net/`、從 App assets 回應檔案、為書籍文件加上 CSP 標頭、其他網址一律回 403；並開啟 WebView 偵錯，讓我從主機用 DevTools 協定執行檢查（`prototype/cdp-fast.mjs`，流程腳本在 `prototype/android/`）。

### 4.2 驗證方法

不靠目測。對每個字元取 `Range.getClientRects()`，算出它屬於哪一欄，並檢查：

1. 文件順序與欄順序一致；
2. 沒有字跨進相鄰欄、沒有字被裁在內容區外；
3. 實際翻過每一個跨頁，收集「完全可見」的字，依閱讀順序（直書右欄→左欄、橫書左欄→右欄）串起來，必須**恰好等於全文**：不缺、不重複、不亂序、沒有只露出一部分的字。

在 Android 模擬器上，第 3 步太慢：第一次嘗試（每個跨頁對 2 個 iframe 量測全部 5,829 字，並載入 24 MB 字型）在 50 分鐘上限內連第一個案例都沒跑完。所以 Android 改用較省的等價檢查 `verifyFast()`：第 1、2 步照做（逐字一次）；翻頁時只檢查每欄的首字與尾字「完整可見」、前一欄的尾字與下一欄的首字「完全不可見」，雙欄時再檢查欄位在左右哪一側。當第 1 步沒有順序違規、第 2 步沒有越界時，每個字只屬於一欄、各欄是連續區段，加上邊界檢查就能推得不缺、不重複、不亂序；若有順序違規，就要逐一查明那些字（見 4.3 節）。這個方法本身的可信度：在桌面 Chromium 153 上，它與完整檢查的結論相同（各模式 0 失敗、首跨頁邊界相同）；故意把翻頁位移算錯的負對照組則報出 45 個失敗。Android 上的匯入字型也改用只含測試用字的子集（Noto Serif CJK TC，161 KB，仍有 `vhea`、`vmtx`、`vert`、`vrt2`）。

### 4.3 結果

**桌面 Chromium 153.0.8010.12（Playwright，視窗 1000×600，邊距上下 40、左右 30，欄間距 40，字級 20，行距 1.8）**【已查證】

| 模式 | 欄數／跨頁 | 缺漏 | 重複 | 亂序 | 部分可見 | 第一跨頁 |
|---|---|---|---|---|---|---|
| A 直書雙欄 | 32／16 | 0 | 0 | 0 | 0 | 右欄第 0–186 字，左欄 187–384 字 |
| B 直書雙欄 | 32／16 | 0 | 0 | 0 | 0 | 與 A 完全相同 |
| A、B 直書單欄 | 15／15 | 0 | 0 | 0 | 0 | 第 0–412 字 |
| H 橫書雙欄 | 27（補成 28）／14 | 0 | 0 | 0 | 0 | 左欄 0–186，右欄 187–421 |
| H 橫書單欄 | 18／18 | 0 | 0 | 0 | 0 | 第 0–295 字 |

**Android 8.0 模擬器、WebView（Chrome）69.0.3497.100**（手機橫向，頁面視窗 684×412 dp，裝置像素比 2.625；`CSS.supports('column-wrap','wrap')` 為 false；方法為 4.2 節的 `verifyFast()`）【已查證】

| 模式 | 欄數／跨頁 | 順序違規 | 跨欄 | 裁切 | 邊界檢查 | 失敗 | 第一跨頁 |
|---|---|---|---|---|---|---|---|
| B 直書雙欄 | 66／33 | 0 | 0 | 0 | 258 | **0** | 右欄第 0–96 字，左欄 97–177 字 |
| A 直書雙欄（此版本不支援 `column-wrap`） | 53／27 | 0 | **925** | 0 | 158 | **62** | 不成立：文字沒有分欄 |
| H 橫書雙欄 | 66／33 | 5 | 0 | 0 | 196 | **0** | 左欄 0–60，右欄 61–153 |
| B 直書單欄 | 30／30 | 15 | 0 | 0 | 118 | **0** | 第 0–186 字 |

- 結論：做法 B 在 WebView 69 上正確；做法 A 在不支援 `column-wrap` 的 WebView 上會失敗，所以「先偵測、不支援就改用 B」是必要的。
- 同一個 App 在另一種畫面設定（2000×1200、density 2.0，視窗 1000×552）下也跑過 B 直書雙欄：32 欄／16 跨頁，126 個邊界檢查 0 失敗。
- 順序違規都來自注音字元，位置落在前一欄：B 單欄的 15 個在同一次執行中逐一確認都是 `<rt>` 內的字；H 的 5 個是在之後另一次執行（畫面尺寸略有不同，60 欄）中確認 5 個全是 `<rt>`。查證後是真實的排版錯誤（注音被畫到前一頁），見 4.5 第 6 點。違規只出現在注音，本文的字沒有缺漏或重複。
- 書內腳本、外部圖片：與桌面相同，腳本被 sandbox 擋下、外部圖片被 CSP 擋下且 `shouldInterceptRequest` 沒有收到該請求（logcat 中 console 訊息）。
- 匯入字型（子集）在兩個 iframe 都是 `loaded`；註腳連結判定正確；閱讀位置：字級 20→26 後該字在第 8 跨頁可見，恢復預設後回到第 5 跨頁。
- 第一次嘗試時 DevTools 的 `Page.captureScreenshot` 在此模擬器上不會回傳，導致測試掛住；改用 `adb exec-out screencap` 截圖後正常。

其他驗證（桌面 Chromium 153）【已查證】：

- 書內 `<script>` 與 `onerror` 屬性：沒有執行。console 出現「Blocked script execution … the document's frame is sandboxed and the 'allow-scripts' permission is not set」。
- 外部圖片 `https://example.com/track.png`：被 CSP 擋下，沒有發出網路請求（Playwright 的請求攔截沒有收到）。Android WebView 69 上相同：console 出現「Refused to load the image … violates the following Content Security Policy directive」，`shouldInterceptRequest` 也沒有收到這個網址。
- 註腳連結：殼層用 `elementFromPoint` 從外部判定點擊位置是 `<a href="#note1">`，不需要讓書籍文件接收觸控。
- 匯入字型：`@font-face` 載入成功（`document.fonts.check` 為 true），直書與橫書都套用。
- 閱讀位置：在第 5 個跨頁記下第一個字，改設定、重新分頁後找回該字。共三組：B 直書雙欄依序改字級 20→26、行距 1.8→2.2、左右邊距 30→80；A 直書雙欄改字級 20→26、字距 0.05→0.2 em；H 橫書雙欄改字級 20→26、縮排 1→2 字並段距 0.5→1.5 em。每一步該字都仍在新的跨頁內；每組最後恢復預設，都回到第 5 個跨頁且首字相同。
- `CSS.supports('column-wrap', 'wrap')`：Chromium 153 為 true。

原始數據：`results/chromium153-full-walk.json`（桌面完整逐字檢查）、`results/android8-webview69-verifyFast.json`（Android 手機橫向那一次執行）。

### 4.4 截圖

- `screenshots/chromium153-A-vertical-2col-spread0@2x.png`：做法 A，第一跨頁（右欄先讀，欄間有淡分隔線）
- `screenshots/chromium153-B-vertical-2col-spread0@2x.png`：做法 B，第一跨頁（與 A 像素相同）
- `screenshots/chromium153-B-vertical-2col-figure.png`：含插圖的跨頁（插圖限制在欄內）
- `screenshots/chromium153-H-horizontal-2col-spread0.png`：橫書雙欄（左欄先讀）
- `screenshots/font-vertical-metrics-comparison@2x.png`：缺少直排度量的字型 vs. 正常字型（見 4.5 第 1 點）
- `screenshots/android8-webview69-B-vertical-2col-spread0.png`：Android 8.0／WebView 69，做法 B 第一跨頁
- `screenshots/android8-webview69-A-without-column-wrap-spread0.png`：同環境套用做法 A（不支援 `column-wrap`）：文字沒有分欄、壓過中間分隔線
- `screenshots/android8-webview69-H-horizontal-2col-spread0.png`：同環境的橫書雙欄
- `screenshots/android8-webview69-ruby-at-page-start.png`：4.5 第 6 點的注音錯位（左：前一頁左緣多出的注音；右：本字旁缺少注音）

直排呈現的實際檢視（驗收第 6 項的初步結果，桌面 Chromium 153、Noto Serif CJK TC）：「。」「，」「、」使用直排字形；「」『』（）轉為直排括號；「……」「——」為直排；「12」「31」縱中橫正確；注音標在字的右側；英文單字 WebView 與半形數字「1」「6」橫躺（這是 CSS `text-orientation: mixed` 的標準行為），全形「１」直立。這只是桌面結果，Android 上還要用系統字型與匯入字型各檢視一次。

### 4.5 原型中發現、會影響設計的問題

1. **匯入的字型若缺少正確的直排度量，直排會壞掉**【已查證】。第一次截圖時「也要檢查。」被畫成「也要檢。查」且字疊在一起。原因：
   - IPAGothic（日文字型）沒有簡化字形的「查」（U+67E5），退回系統的文泉驛正黑；
   - 文泉驛正黑的 `vmtx` 表中，漢字的直排前進量（advanceHeight）都是 0（橫排為 1024），也沒有 `vert` 特性（以 fontTools 讀字型檔確認）。
   這是此 Linux 測試環境的字型，但使用者匯入任意字型時可能遇到同樣問題。【建議】匯入字型時讀字型表（`vhea`／`vmtx` 是否存在、前進量是否為 0、有無 `vert`／`vrt2`），有問題就提示「此字型可能不適合直書」，但仍允許使用。
2. **注音 ruby 在欄邊會超出欄框約 1 px**【已查證】（橫書單欄有 30 個注音字元 top = −1 px）。【建議】每欄四周保留 8 px 的溢出緩衝。原型採用後，被裁切的字為 0。
3. **欄數為奇數時，最後一個跨頁的捲動會被瀏覽器夾住**，造成上一欄重複顯示（第一次測試橫書雙欄重複 247 字）【已查證】。【建議】A／H 在欄數為奇數時補一個空白欄；B 隱藏最後一跨頁多出的左框（原型已採用，之後重複為 0）。
4. **舊版 WebView 的語法限制**：第一版原型用到的語法有些舊版 WebView 不支援，所以在上 Android 測試前就先改寫（不是上機後才發現失敗）。殼層必須避開：`?.`、`??`（Chrome 80 起）、物件展開（60 起）、`replaceChildren`（86 起）、CSS `inset`（87 起）；版面屬性改用實體屬性（如 `margin-left`），因為邏輯屬性 `margin-block-end` 自 69 起才支援。版本依據：MDN browser-compat-data 8.1.9【已查證】。改寫後的版本在 WebView 69 上可執行（第 4.3 節）。
5. **效能**【已查證，桌面數字】：單章約 15 萬字（492 KB XHTML）時，A 雙欄首次排版約 190–280 ms，B 雙欄約 410–510 ms（B 排版兩次，約為 A 的兩倍），翻頁約 1 ms。手機會更慢，【建議】過大的章節要先切分（見 5.9）。
6. **舊版 WebView 中，位於一頁（欄）第一行的注音會畫到前一頁**【已查證，WebView 69】：在 B 直書單欄中，第 4 頁第一行的「漢字」旁沒有注音，注音「ㄏㄢˋ ㄗˋ」被畫在第 3 頁的左緣（見截圖 `android8-webview69-ruby-at-page-start.png`）。H 橫書也有同類情形（5 個字元）。桌面 Chromium 153 沒有這個問題（注音留在本字旁的溢出緩衝內）。哪一版 Chromium 開始沒有此問題，我沒有查證。【推論】原因是行距 1.8 時行框容納不下注音，超出欄框的部分在舊版多欄排版中被對應到前一欄。【建議】階段 4 測試緩解方式：只對含 `<ruby>` 的行加大行高（例如 `ruby { line-height: … }`），讓注音落在行框內；若無法完全避免，列為舊版 WebView 的已知限制。

### 4.6 尚未驗證的部分

- 做法 A 在 Android WebView 145 以上的行為：只在桌面 Chromium 153 驗證。
- WebView 58（Android 8.0 從未更新 WebView 的裝置）：AOSP 映像沒有可用的 WebView，無法測；WebView 69 已測。
- 4.5 第 6 點注音錯位的緩解方式：尚未測試。
- 插圖跨頁在 WebView 69 上的截圖被系統的「System UI isn't responding」對話框遮住（純軟體模擬太慢造成），未放入；該模式的數據檢查已通過。
- 實機效能與實機字型。
- 真實出版品：目前只用自撰內容。

---

## 5. 設計提案

### 5.1 架構總覽

```
Local Source 作品資料夾
  └─ 章節檔：.epub / .mobi / .azw3
        │
        ▼
:core:ebook（新 Gradle 模組，Android library）
  ├─ 格式判定（副檔名＋檔頭）、DRM／損毀偵測
  ├─ EPUB 解析：OPF、spine、nav／NCX 目錄、metadata、書寫方向、字型反混淆
  ├─ MOBI 6／KF8（AZW3）解析：PDB、PalmDOC、HUFF/CDIC、FDST/SKEL/FRAG、內嵌資源
  ├─ 內容清理（jsoup）：移除 script、事件屬性、外部嵌入
  └─ Publication 模型：spine 項目、資源、目錄、語言、書寫方向
        │
        ▼
:app 的新 package yokai.ebook
  ├─ EbookReaderActivity：WebView ＋ 原生介面（上方列、進度滑桿、目錄、設定面板）
  ├─ 虛擬網域請求處理：只回應殼層與書內資源，其他一律 403；書籍文件加 CSP
  ├─ 殼層 assets（原型的正式版）
  ├─ 閱讀位置：獨立小型資料庫 ebook.db；同時更新 last_page_read／pages_left、已讀、閱讀紀錄、追蹤
  └─ EbookPreferences（排版設定）、FontStore（匯入字型）
```

### 5.2 格式解析

- **EPUB**：沿用專案已有的 libarchive `ArchiveReader` 讀 zip、jsoup 解析 OPF 與 XHTML，不需要新函式庫。目錄優先用 EPUB 3 的 nav，沒有時用 EPUB 2 的 NCX。書寫方向依 spine 的 `page-progression-direction`、語言、CSS 的 `writing-mode` 判斷。
- **字型反混淆**：支援 IDPF 與 Adobe 的字型混淆演算法。這只是防止字型被直接取出，不是 DRM，EPUB 規格允許閱讀器處理。
- **MOBI／AZW3**：以 Kotlin 自行實作。參考資料是 MobileRead wiki 的格式說明，以及 foliate-js 的 `mobi.js`（MIT；整個專案為 MIT，`mobi.js` 檔內沒有註明衍生自 GPL 程式）。
  - 不採用 libmobi：LGPL-3.0，需要 NDK 建置 4 種 ABI，並承擔讓使用者替換函式庫的義務。
  - 不採用 KindleUnpack、Calibre：GPL-3.0，不能併入 Apache-2.0 的專案。
  - 舊版 MOBI 6：全書是一段 HTML，依 `<mbp:pagebreak>` 與大小切成多個 spine 項目；處理 `filepos` 連結與 `recindex` 圖片。
  - KF8（AZW3，以及合併式 .mobi 的 KF8 部分）：依 FDST／SKEL／FRAG 表重建各個 HTML 檔，處理 `kindle:embed`、`kindle:pos` 連結與內嵌字型。
- **文字書或漫畫型 EPUB 的判定**（第 7 題）：`rendition:layout=pre-paginated`（固定版面）→ 漫畫閱讀器；否則統計 spine 內的非空白字數與圖片數，文字極少且幾乎每頁都有圖 → 漫畫閱讀器。門檻會用測試書校正。判定結果快取，並可手動切換。
- 解析程式放在新模組 `:core:ebook`，可用 JVM 單元測試覆蓋。

### 5.3 排版殼層（WebView）

- 一次載入一個 spine 文件（過大的文件切成片段），並預先載入下一個。
- 模式：橫書用 H；直書單欄用傳統直排分頁；**直書雙欄**在 `CSS.supports('column-wrap','wrap')` 為真時用 A（只排版一次），否則用 B。原型中兩者的分欄結果完全相同，切換對使用者透明。【建議】B 是基準實作，A 是最佳化，另保留一個除錯開關可強制使用 B。
- 排版設定以注入的 CSS 套用，一律使用舊版 WebView 支援的寫法（見 4.5 第 4 點）。
- WebView 的 `textZoom` 固定為 100，讓 App 內的字級設定是唯一依據（系統字型大小對 WebView 的影響會在實作時於模擬器確認）。

### 5.4 與既有架構的整合點

**要修改的既有檔案**（盡量少）：

| 檔案 | 改動 |
|---|---|
| `settings.gradle.kts` | `include(":core:ebook")` |
| `app/build.gradle.kts` | 依賴 `:core:ebook`；新增 flavor（見 5.10） |
| `source/LocalSource.kt` | 章節過濾加入 `mobi`、`azw3`；`Format` 新增 MOBI；MOBI 的 metadata 與封面 |
| `ui/reader/ReaderViewModel.kt`、`ReaderActivity.kt` | 判定為文字書時切換到 `EbookReaderActivity` |
| `AndroidManifest.xml` | 註冊 `EbookReaderActivity`（第 2 題若要「以此 App 開啟」，另加 intent-filter） |
| `i18n/.../base/strings.xml`、`zh-rTW/strings.xml` | 新字串 |

**導向方式**【建議】：新增獨立的 `EbookReaderActivity`，不在 `ReaderActivity` 內新增 viewer。理由：

- `ReaderActivity`（2,152 行）大量邏輯以「圖片頁」為前提：頁碼滑桿、雙頁、裁邊、長按存圖、多處 `viewer is R2LPagerViewer` 分支。把文字 viewer 塞進去要改動很多既有分支。
- 文字書的頁數會隨排版改變，與 `ReaderPage` 的模型不合。
- 分開後，日後合併上游更新的衝突較少。

代價：章節面板、已讀、閱讀紀錄、追蹤要在新 Activity 重新接上（會重用既有的 interactor 與 `updateTrackChapterRead`）。

**導向時機**：`.mobi`／`.azw3` 只看副檔名，可在 `ReaderActivity.newIntent` 直接導向。`.epub` 需要讀內容判定，放在背景執行：`ReaderActivity` 原本就先顯示「請稍候」，判定為文字書就切換到 `EbookReaderActivity`。文字書內的「下一章」若是圖片章節，反向切回 `ReaderActivity`。

### 5.5 閱讀位置

- **定位資訊**：spine 項目、DOM 路徑＋字元位移、附近一小段文字（容錯用）、章內與全書進度百分比。
- **儲存位置**【建議】：獨立的小型資料庫 `ebook.db`，主鍵用（來源 id、作品 url、章節 url），**不新增主資料庫的 migration**。理由：
  - 主資料庫的 migration 編號是連續的。fork 自行新增 `31.sqm` 後，若上游日後也新增 `31.sqm`，合併時會衝突，且使用者的資料庫版本會領先上游。
  - 還原備份後章節 id 會改變，url 才是穩定的鍵。
- **與既有欄位的關係**：照常更新主資料庫的 `last_page_read`／`pages_left`（以當下排版的頁數計），讓章節列表的剩餘頁數、繼續閱讀等既有介面正常運作；讀到最後一頁時標記已讀、寫入閱讀紀錄（含閱讀時間）、觸發追蹤更新，行為與漫畫閱讀器一致。
- **還原順序**：依 DOM 路徑定位；失敗時以文字片段搜尋；再失敗則用百分比。原型已驗證「依字元還原」在改設定後仍正確（4.3 節）。
- **備份**：見第 7 節新增問題 A。

### 5.6 設定（任務文件 2.3 第 1–9 項）

數值是我的提案。Readium（`EpubPreferencesEditor.kt`）與 KOReader（`creoptions.lua`、`defaults.lua`）是我讀過原始碼、可查證的開源參考；商用閱讀器的數值我沒有查證，所以沒有列入。

| # | 設定 | 選項／範圍 | 步進 | 預設 | 參考 |
|---|---|---|---|---|---|
| 1 | 字體 | 書籍指定／系統無襯線／系統襯線／已匯入的字型 | — | 書籍指定 | — |
| 2 | 行距 | 1.0–3.0 倍字級 | 0.1 | 1.8 | Readium 1.0–2.0（0.1）；KOReader 50–200% |
| 3 | 首行縮排 | 依書籍／0–4 字 | 0.5 字 | 依書籍 | Readium 0–3（0.2） |
| 4 | 字級 | 12–48 | 1 | 20 | KOReader 12–44（預設 22）；Readium 10%–500% |
| 5 | 字距 | 0–0.50 em | 0.05 | 0 | Readium 0–1.0（0.1） |
| 6 | 段落間距 | 依書籍／0–3.0 em | 0.1 | 依書籍 | Readium 0–2.0（0.1） |
| 7 | 上、下、左、右邊距 | 各自 0–120 dp | 2 dp | 上下 32、左右 20 | KOReader 左右可調 0–140、上下預設選項 5–140 |
| 8 | 書寫方向 | 依書籍／直書／橫書 | — | 依書籍 | — |
| 9 | 雙欄 | 關閉／開啟／僅橫向畫面 | — | 僅橫向畫面 | KOReader 1 或 2 頁 |
| — | 欄間距 | 固定 40 dp（第 9 題） | — | — | — |
| — | 背景與文字顏色 | 沿用既有的閱讀器主題設定 `readerTheme` | — | — | — |

- 「依書籍」表示不覆寫出版品自己的 CSS；選了數值才覆寫。
- 字級單位是 WebView 的 CSS px，等於 dp【已查證：Android 8.0 模擬器、WebView 69，畫面 2000×1200、density 2.0 時，頁面回報視窗 1000×552（高度已扣除導覽列）、devicePixelRatio 2】。
- 設定面板：閱讀器內的底部面板，分「文字」「版面」兩頁；調整時即時重新分頁，並回到同一個字。
- 儲存：新的 `EbookPreferences`，鍵名以 `pref_ebook_` 開頭，所有書共用（第 4 題）；會隨既有機制自動進備份。匯入字型的清單用 `__APP_STATE_` 開頭的鍵（不進備份），字型檔放在 App 私有目錄 `files/fonts/`。

### 5.7 安全（任務文件第 5 節）

- **書內腳本**：三層防護：iframe `sandbox="allow-same-origin"`（無 `allow-scripts`）、書籍文件的 CSP `script-src 'none'`、以 jsoup 移除 `<script>`、`on*` 屬性、`javascript:` 連結、`<iframe>`／`<object>`／`<embed>`／`<form>`。原型：腳本沒有執行（Chromium 153、WebView 69）。
- **連網**：`shouldInterceptRequest` 只回應虛擬網域下的殼層與書內資源，其他一律 403；CSP `default-src 'self'`、`connect-src 'none'`；主框架的導航一律攔截。原型：外部圖片在發出請求前就被 CSP 擋下。
- **讀取 App 其他檔案**：WebView 設 `allowFileAccess=false`、`allowContentAccess=false`；資源路徑只在書內解析，拒絕 `..` 與絕對路徑。
- **原生橋接**：不用 `addJavascriptInterface`。Android 官方文件寫明「The object is injected into all frames of the web page, including all the iframes」【已查證】，書籍 iframe 也會拿到這個物件。改用 androidx.webkit 的 `WebViewCompat.addWebMessageListener` 並限定來源；舊版 WebView 不支援此功能時（以 `WebViewFeature.isFeatureSupported` 判斷），改用框架的 `WebView.postWebMessage` 建立 MessagePort（官方文件：「Post a message to main frame」，只送到主框架）。
- **觸控**：書籍 iframe 不接收觸控，點擊由原生層處理，連結以 `elementFromPoint` 判定。
- **外部連結**：見第 7 節新增問題 B。
- **再加一層**：`WebSettings.setBlockNetworkLoads(true)`。【已查證，WebView 69】開啟後，殼層與書籍仍能從 `shouldInterceptRequest` 提供的虛擬網域正常載入（測試 App 以 `blockNetworkLoads=true` 啟動，書籍開啟成功、29 欄）。

### 5.8 DRM 與損毀檔

- **偵測**：EPUB 的 `META-INF/encryption.xml` 中字型混淆以外的加密項目、`rights.xml`（Adobe ADEPT）、`sinf.xml`（Apple）、`license.lcpl`（Readium LCP）；MOBI／AZW3 檔頭的加密類型欄位不為 0；KFX 容器（較新的 Kindle 格式，不在需求內）。
- **處理**：顯示「此檔案受 DRM 保護，無法開啟」等說明，不當機，不嘗試解密。
- **損毀**：解析例外統一轉成「檔案損毀或格式不支援」的訊息；解壓縮設大小上限，避免壓縮炸彈。

### 5.9 效能

- 單一 spine 文件過大時，在段落邊界切成多個片段（門檻在實機校正）；舊版 MOBI 依 `<mbp:pagebreak>` 切。
- 全書字數（進度百分比用）在背景計算，快取在 `ebook.db`。
- 做法 B 排版兩次，做法 A 一次。
- 驗收第 9 項的開啟時間需在實機量測，模擬器數字不具參考性。

### 5.10 App 身分與 Firebase（第 1 題，任務文件第 5 節）

【建議】新增一個 product flavor（暫名 `ebook`）：

- applicationId 改成新的（與官方版並存），App 名稱改成可區分的名字（第 1 題）。
- 不套用 Google Services 與 Crashlytics 外掛。`app/build.gradle.kts` 目前以「任務名稱含 standard」決定是否套用，新 flavor 名稱不含 standard，自然不會套用 → 不會把當機報告或分析資料送到上游的 Firebase 專案。
- `INCLUDE_UPDATER=false`，否則會提示下載上游的版本。
- 保留所有語系資源（不像 `dev` flavor 只留英文）。
- 既有的 `standard`、`dev` flavor 保持不變，方便和上游比對。

### 5.11 第三方元件與授權

- **執行期**：不新增第三方函式庫。沿用專案已有的 jsoup、libarchive、androidx.webkit。
- **參考來源**：foliate-js（MIT）。若移植其中的邏輯，會保留 MIT 聲明並列入 App 內的開源授權清單。
- **只用於測試、不打包**：Noto Serif CJK（SIL OFL 1.1）、Playwright、Chromium。

### 5.12 測試計畫

- `:core:ebook` 的 JVM 單元測試：EPUB／MOBI／KF8 解析、DRM 判定、路徑解析、內容清理。
- 殼層：沿用原型的逐字驗證腳本，在桌面 Chromium 與 Android 模擬器（WebView 69）各跑一次。
- 回歸：基線 54 個單元測試；模擬器上的冒煙測試（書庫、Local Source 的資料夾／壓縮檔／漫畫型 EPUB、備份與還原）。
- 測試書：自製（腳本產生 EPUB；MOBI／AZW3 打算用 Calibre 的 `ebook-convert` 轉檔產生。Calibre 是 GPL 程式，只當作產生測試檔的外部工具，不併入 App；能否在此環境安裝待確認）＋公版書（例如 Project Gutenberg、青空文庫，可否連線待確認）。報告會註明來源。

### 5.13 風險

1. 舊版 WebView（Android 8／9 未更新）：只測過 69 與桌面 153。
2. `column-wrap` 是 2026 年才上線的功能，只在桌面 153 驗證過；B 作為基準可以降低風險。
3. 匯入字型缺少直排度量（4.5 第 1 點）。
4. 【推論】中文轉檔書常以全形空白「　　」做段首縮排，再套用首行縮排設定會變成雙重縮排。預設「依書籍」可以避免；是否要額外處理不在需求內，暫不做。
5. KF8 的 HUFF/CDIC 解壓縮效能（foliate-js README 自述其實作較慢）。
6. 效能只能在實機量測。
7. 舊版 WebView 會把位於頁首行的注音畫到前一頁（4.5 第 6 點，WebView 69 實測）；緩解方式待階段 4 測試。

---

## 6. 階段規劃（照任務文件，只補充內容）

| 階段 | 內容 | 交付與驗證 |
|---|---|---|
| 2 格式 | `:core:ebook`（EPUB、MOBI、AZW3、DRM 判定）、Local Source 列出新格式、文字／漫畫判定、最小可讀的文字閱讀器（單欄、預設排版） | 單元測試；模擬器上開啟三種格式並翻到最後一頁；漫畫型 EPUB 行為不變 |
| 3 排版設定 | 2.3 第 1–8 項、設定面板、字型匯入與檢查、設定保存 | 每項設定的畫面變化截圖；重啟後保留 |
| 4 雙欄 | 橫書雙欄；直書左右雙欄（A＋B 後備） | 逐字驗證腳本：WebView 69（B）＋桌面 153（A）；實機待你協助 |
| 5 整合 | 閱讀位置、已讀、閱讀紀錄、追蹤、點擊區域與音量鍵 | 關閉重開、旋轉、改設定後回到同一段 |
| 6 回歸與交付 | 回歸測試、APK、文件 | 驗收第 8 節各項 |

---

## 7. 需要你決定的事項

每題附上我的建議。你可以只回覆「同意」或寫下不同的決定；回覆後我會把決定補進本文件，再開始階段 2。

### 任務文件第 6 節的 11 題

1. **App 身分**【建議】新的 applicationId 與名稱，與官方版並存；用新的 flavor，不套用 Firebase 外掛、不檢查上游更新（見 5.10）。**請提供**：App 名稱與套件名稱。
   - 套件名稱：若沒有偏好，我先沿用專案的命名方式（基底 `eu.kanade.tachiyomi` 加後綴），用 `eu.kanade.tachiyomi.yokaiebook`，之後可以再改。
   - App 名稱：請你決定。專案的 Apache-2.0 授權第 6 條寫明「This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor」，所以【建議】名稱與「Yōkai」明顯區分；在「關於」頁註明衍生自 Yōkai 屬於該條允許的「describing the origin of the Work」。
2. **電子書入口**【建議】先只做 Local Source（`.epub`、`.mobi`、`.azw3` 放進作品資料夾，一個檔案一個章節）。
3. **書內導覽**【建議】兩者都做：全書進度滑桿（百分比）＋目錄跳轉。
4. **設定的作用範圍**【建議】所有書共用一組。
5. **閱讀順序與翻頁方向**【建議】直書右欄先讀、下一頁在左；橫書左欄先讀、下一頁在右；點擊區域、音量鍵沿用 Yokai 既有的閱讀器設定。
6. **直書／橫書的初始值**：需要你澄清。任務文件的建議是「第一次開啟依書籍本身，使用者選過之後以使用者的選擇為準」。這可以有兩種意思：
   - (a) 全域設定三選一「依書籍／直書／橫書」，預設「依書籍」，你一改就套用到所有書；
   - (b) 每本書各自記住你的選擇。
   【建議】(a)，與第 4 題「所有書共用一組設定」一致。
7. **圖文混合的 EPUB**【建議】自動判定（規則見 5.2），並可手動切換；切換結果記在該章節。
8. **字體**【建議】從裝置匯入 TTF、OTF；不內建字體，只提供「書籍指定／系統無襯線／系統襯線／已匯入的字體」。另外【新增】匯入時檢查直排度量，有問題時提示但仍允許使用（見 4.5 第 1 點）。
9. **邊距與欄間距**【建議】四邊各自獨立調整；欄間距先固定 40 dp。
10. **APK 的建置與簽章**【建議】交付 release 建置（R8 最佳化），arm64-v8a 與 universal 兩種。簽章請選一種：
    - (a) 我在此環境產生一把新的金鑰簽章，把 keystore 檔和密碼一起交給你；之後的更新必須用同一把金鑰，請自行妥善保存。
    - (b) 你提供自己的 keystore。金鑰不能貼在對話中，需要另外安排傳遞方式。
    - (c) debug 簽章：最簡單，但此雲端容器回收後金鑰就消失，之後的版本無法直接覆蓋安裝，必須先解除安裝（會清除 App 資料）。
11. **介面語言**【建議】新增字串同時提供英文原文與繁體中文（`zh-rTW`）。

### 我新增的問題

- **A. 文字書的精確閱讀位置要不要進備份檔？**
  - 要：需在備份 protobuf 新增欄位（使用不會與上游衝突的大編號，不動既有編號）。舊版 Yokai 讀到這種備份會忽略新欄位。
  - 不要：還原後只保留主資料庫的頁數層級進度（`last_page_read`），精確到字的位置會遺失。
  【建議】要。
- **B. 書中的外部連結（http／https）怎麼處理？**
  - (a) 一律不開啟，點擊時顯示「已封鎖外部連結」；
  - (b) 點擊後詢問是否用瀏覽器開啟。
  【建議】(a)。書內的註腳、目錄等內部連結照常跳轉。
- **C. 閱讀器的架構**【建議】獨立的 `EbookReaderActivity`（理由見 5.4）。若你比較希望文字書與漫畫共用同一個閱讀畫面（介面較一致，但要改動較多既有程式），請告訴我。

### 也請確認

- 第 5.6 節設定表的範圍、步進與預設值。

---

## 8. 決定紀錄（2026-11-18，使用者回覆）

以下照使用者回覆整理；「重述」是我的理解，已請使用者確認。

| # | 使用者的決定 | 後續 |
|---|---|---|
| 1 | App 名稱與套件名稱：Bookmania | 套件名稱需含點，建議 `io.github.n09527.bookmania`；使用者回覆「可以？」，我暫以此名稱進行，**如要更改請告知**（發佈給他人之前都能改；已安裝的 App 換套件名稱，系統會視為另一個 App） |
| 2 | 先只做 Local Source | 定案 |
| 3 | 進度滑桿與目錄兩者都做 | 定案 |
| 4 | 可預設全域設定，之後閱讀時每本書也可以單獨設定。追加說明：「可以有一個全域設定，做為所有檔案的預設值。之後每個檔案或作品閱讀時，可以各自改各自設定」 | 重述：三層，近的優先——全域 → 作品（Local Source 的資料夾）→ 單一檔案。沒有單獨設定的項目沿用上一層。如果你的意思只要兩層（全域 → 每個檔案），請告知 |
| 5 | 直書右欄先讀、橫書左欄先讀、操作沿用既有設定：是；但要能自行選擇左開／右開，捲曲的翻頁動畫也要依此調整方向。追加回覆：捲曲動畫「所有閱讀器都要有」；動畫提供「捲曲／滑動／無」三種：「好」；雙欄時的捲曲方式：「中線」 | 定案：文字閱讀器新增「翻頁方向：右開／左開」（預設依直橫書，可全域設定、可每本書另設）；所有閱讀器（含既有漫畫閱讀器）可選「捲曲／滑動／無」，捲曲方向依左右開；雙欄時以中線為軸翻一頁。漫畫閱讀器既有的預設行為不變，捲曲是新增選項。**待確認**：長條（webtoon）模式不提供捲曲；直向翻頁模式的捲曲從下緣往上 |
| 6 | 直橫書：可預設全域設定，之後每本書也可以單獨設定 | 與第 4 題相同機制 |
| 7 | 圖文混合 EPUB：自動判定並可手動切換 | 定案 |
| 8 | 字體：匯入 TTF／OTF、不內建、匯入時檢查直排度量 | 定案 |
| 9 | 四邊邊距各自調整，欄間距固定 40 dp | 定案 |
| 10 | 詢問三種簽章的差異 | 已說明，**待選擇** |
| 11 | 新字串同時提供繁體中文 | 定案 |
| 12 | 精確閱讀位置寫進備份 | 定案；每本書的單獨設定也一併寫進備份 |
| 13 | 外部連結：詢問後用瀏覽器開啟 | 定案：對話框顯示網址，確認後交給系統瀏覽器；WebView 本身不載入 |
| 14 | 原始碼放在 https://github.com/N09527/bookmania | 這個 session 尚未連結 GitHub 帳號，暫時無法推送 |
