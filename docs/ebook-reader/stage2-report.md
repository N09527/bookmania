# Bookmania 階段 2 報告：格式

- 日期：2026-11-18
- 分支：`ebook-reader/stage1-design`（本機；推送到 N09527/bookmania 仍被拒，見第 7 節）
- 標示：【已查證】＝本次實際執行或實測；【推論】＝由事實推導、未實測。

---

## 0. 摘要

1. **三種格式都能讀**【已查證】：Local Source 會列出 `.epub`、`.mobi`、`.azw3`，文字書以新的文字閱讀器開啟（單欄、預設排版，直書右開、橫書左開）。10 本測試書（直排 4、橫排 6，涵蓋 EPUB 2／3、KF8、合併式 MOBI、MOBI 6、圖文混合）在 Android 8.0 模擬器上從第一頁翻到最後一頁，每頁「完全可見的字」串起來與全文逐字相同，沒有缺字、重複，段落順序正確。
2. **DRM**【已查證】：受保護的 EPUB（Adobe ADEPT）與 MOBI 都顯示清楚的說明畫面，不解密、不當機。
3. **漫畫閱讀器**【已查證】：CBZ 照常開啟。漫畫型 EPUB 交回既有閱讀器，但**既有閱讀器本身就打不開這兩本 EPUB**（「No pages found」）——原因在上游讀 OPF 的方式（第 6.2 節），我沒有修改那段程式。
4. **測試**【已查證】：所有單元測試通過（`:app` 22、`:domain` 34、`:core:ebook` 32）；上游原有的 54 個與基線相同。
5. **既有檔案只改了 7 個、共 +74／−2 行**，新功能都在新模組 `:core:ebook` 與新 package `yokai.ebook`。沒有動 migration、備份欄位、既有偏好設定鍵；minSdk 26。
6. **未做／未驗證**：實機、閱讀位置與已讀紀錄（階段 5）、排版設定（階段 3）、雙欄（階段 4）等，見第 5 節。
7. **需要你處理**：GitHub 推送權限（仍 403）、簽章方式、App 圖示、上游兩個既有問題要不要修，見第 7 節。

---

## 1. 做了什麼

### 1.1 `:core:ebook`（新模組，JVM 可測）

| 部分 | 內容 |
|---|---|
| 格式判定 | 副檔名＋檔頭：ZIP 第一個項目 `mimetype` → EPUB；PDB 類型 `BOOKMOBI`／`TEXtREAd` → MOBI；`CONT`、`\xEADRMION` → KFX（不支援，顯示說明） |
| EPUB | `container.xml` → OPF；spine、`linear`；目錄（EPUB 3 nav，沒有時用 EPUB 2 NCX）；metadata（書名、作者、語言、出版者、日期、封面）；固定版面判定；`page-progression-direction`；IDPF 與 Adobe 字型反混淆；DRM 判定（`encryption.xml` 中非字型混淆的演算法、`license.lcpl`、`sinf.xml`、`rights.xml`） |
| MOBI 6 | PDB 記錄表、PalmDOC 與 HUFF/CDIC 解壓、尾端資料移除；依 `<mbp:pagebreak>` 切成多個 spine 項目；`filepos` 連結、`recindex` 圖片；`<p width height>` 轉成首行縮排與段前空白 |
| KF8（AZW3，以及合併式 .mobi 的 KF8 部分） | FDST／SKEL／FRAG 重建 XHTML；`kindle:pos`、`kindle:embed`、`kindle:flow` 改寫為書內路徑；`aid` 錨點；NCX 目錄；內嵌字型（含混淆與壓縮） |
| DRM | MOBI 標頭 `encryption ≠ 0`、EPUB 上述檔案 → `DrmProtectedException`，不解密、不繞過 |
| 書寫方向 | `WritingModeDetector`：先看實際套用在 `html`／`body` 的 CSS `writing-mode`，再看 metadata（只採信「vertical」），最後看「右開＋中日文＋有直排規則」 |
| 文字／漫畫判定 | 固定版面 → 漫畫；否則統計前 40 個文件的文字量與含圖比例 |
| 內容清理 | XHTML 用 XML 解析、`text/html`（MOBI 6）用 HTML 解析；移除 script、iframe、embed、表單、事件屬性、`javascript:` 等網址；輸出 HTML5 |

授權：MOBI／KF8 解析參考並移植 foliate-js `mobi.js`（MIT）。完整授權文字在 `core/ebook/NOTICE-foliate-js.txt`，移植的檔案開頭有註明，App 的「開源授權」清單以自訂項目列出（`app/aboutlibraries/`）。沒有使用 GPL／LGPL 的程式碼（Calibre 只在本機用來產生測試書，不隨 App 發佈）。

### 1.2 App 端

| 部分 | 內容 |
|---|---|
| `bookmania` flavor | 套件 `io.github.n09527.bookmania`（debug 加 `.debug`）、名稱 Bookmania、預設資料夾 `/sdcard/Bookmania`；不套用 Google Services 與 Crashlytics 外掛、沒有 `google-services.json`、`INCLUDE_UPDATER=false`；保留所有語系 |
| Local Source | 章節清單加入 `.mobi`、`.azw3`（新 `Format.Ebook`），讀取書名、作者、簡介、出版者、日期、封面。EPUB 原有處理不變 |
| 導向 | `.mobi`／`.azw3`：`ReaderActivity.newIntent` 直接改開文字閱讀器。`.epub`：在漫畫閱讀器載入章節時（背景）判定，文字書就交給文字閱讀器；漫畫型 EPUB 照舊。判定結果目前只快取在記憶體 |
| `EbookReaderActivity` | 單欄、預設排版（字級 20、行距 1.8、上下邊距 32 dp、左右 20 dp、背景沿用既有「閱讀器背景色」設定）；直書右開、橫書左開；點擊左右三分之一翻頁、中間開關選單；滑動翻頁；翻頁鍵、方向鍵；「音量鍵翻頁」沿用既有設定；跨章節檔翻頁；書內連結跳轉；外部連結先詢問再交給系統瀏覽器；DRM、損毀、KFX 顯示說明畫面 |
| WebView 安全設定 | 只服務 `https://appassets.androidplatform.net/` 的 `/shell/`（殼層）與 `/book/`（書內資源），其他主機、路徑一律拒絕；`blockNetworkLoads`；不允許檔案與 content 存取；書籍文件經清理並加 CSP（`script-src 'none'`、`connect-src 'none'` 等）；書籍 iframe 為 `sandbox="allow-same-origin"`（不含 allow-scripts）、不接收觸控；WebView 不建立 JavaScript 介面，原生端只用 `evaluateJavascript` 呼叫殼層 |
| 字串 | 新檔 `strings_ebook.xml`（英文＋繁體中文），不改既有字串檔 |

### 1.3 修改的既有檔案（共 7 個，其餘都是新檔）

| 檔案 | 改動 |
|---|---|
| `settings.gradle.kts` | `include(":core:ebook")`（1 行） |
| `app/build.gradle.kts` | 依賴 `:core:ebook`；`bookmania` flavor；用 `androidComponents` 設定其套件名稱；AboutLibraries 自訂項目路徑（共 24 行） |
| `app/src/main/AndroidManifest.xml` | 註冊 `EbookReaderActivity`（不對外公開）（5 行） |
| `source/LocalSource.kt` | 章節過濾、`Format.Ebook`、MOBI 的 metadata 與封面（+18／−1） |
| `ui/reader/loader/ChapterLoader.kt` | EPUB 判定；文字書丟出 `TextBookException`（+8／−1） |
| `ui/reader/ReaderActivity.kt` | `newIntent` 導向；初次載入與換章時交接給文字閱讀器（+7） |
| `ui/reader/ReaderViewModel.kt` | 換章遇到文字書時送出事件（+11） |

沒有修改任何 migration、備份 protobuf 欄位或既有偏好設定鍵；minSdk 維持 26。

---

## 2. 建置與單元測試

【已查證】

| 指令 | 結果 |
|---|---|
| `./gradlew testDebugUnitTest testBookmaniaDebugUnitTest :app:assembleBookmaniaDebug --continue` | 全部通過：`:app` 22 個（上游 20 個＋新增 2 個）、`:domain` 34 個、`:core:ebook` 32 個。上游原有的 54 個與第 0 階段基線的數量相同，沒有失敗 |
| （其中 `:core:ebook` 32 個） | EPUB 8、MOBI／AZW3 8、書寫方向 6、清理器 4、路徑 3、ZIP 2、格式判定 1 |
| （其中新增的 `:app` 2 個） | `LocalEbooksTest`：副檔名判斷、ISO 8601 日期 |
| `./gradlew :app:assembleBookmaniaDebug` | 成功；`output-metadata.json` 的 applicationId 為 `io.github.n09527.bookmania.debug`；產出 arm64-v8a、armeabi-v7a、x86、x86_64、universal 五個 APK |
| `./gradlew :app:prepareLibraryDefinitionsBookmaniaDebug` | 產生的授權清單含 foliate-js 與其 MIT 全文（含 Copyright 行），共 317 項 |

- 此環境記憶體 15 GB，Gradle 常駐程序（6 GB）＋Kotlin 常駐程序（3 GB）＋模擬器（約 4 GB）同時執行時，容器曾被重啟一次（程序以 137 結束）。之後在模擬器執行時改用 `-Dorg.gradle.jvmargs=-Xmx4g -Pkotlin.daemon.jvmargs=-Xmx2500m`，未再發生。只是此環境的限制，與專案無關。
- 第 0 階段基線用的是 `testReleaseUnitTest testStandardReleaseUnitTest`；本階段改跑 debug 變體（`bookmania` flavor），release 變體的單元測試沒有重跑。

---

## 3. 模擬器驗證

環境：Android 8.0（API 26）google_apis x86_64 模擬器，純軟體模擬；WebView 為 Chrome 69.0.3497.100；畫面 1080×1920、density 2.625（網頁視窗 412×732 CSS px）。安裝 `app-bookmania-x86_64-debug.apk`。為了不經過首次使用導覽，事先在 App 偏好設定寫入「導覽已完成」與既有選項「外部 Local Source」，測試書放在 App 專屬資料夾 `Android/data/<套件>/files/local/`。

### 3.1 Local Source【已查證】

- Local Source 列出 15 個測試作品資料夾，包含只有 `.mobi`／`.azw3` 的資料夾（截圖 `screenshots/stage2/02-local-source.png`）。
- MOBI／AZW3 的章節名稱取自書內書名（例：`zh-vertical-joint.mobi` → 「直排測試書」）；章節列上的「Bookmania 測試」是書內作者（與既有 EPUB 的處理相同，放在章節的 scanlator 欄位），日期取自 EXTH 106（截圖 `03-joint-mobi-details.png`）。封面檔 `cover.jpg` 已寫入作品資料夾（與既有「從第一章取封面」機制相同，詳細頁要重新整理才顯示）。
- 受 DRM 保護的 `drm-flagged.mobi`、損毀的 EPUB 保留檔名作章節名稱，列表正常、沒有當機。

### 3.2 文字書：開啟並翻到最後一頁，逐字檢查【已查證】

方法（腳本在 `docs/ebook-reader/tools/stage2/`，主要是 `verify-book.sh`、`probe.js`、`summarize.py`）：從**漫畫閱讀器的入口**（`ReaderActivity`，帶作品與章節 id）開啟，確認最後在前景的是 `EbookReaderActivity`（同時驗證交接）；之後每點一次「下一頁」，透過 WebView 除錯介面讀取 iframe 中**完全落在可視範圍內**的每個非空白字元。每個章節檔把各頁的可見字串依序串起來，與該檔全部有排版的字元比對；相同就表示沒有缺字、沒有重複。注音（`rt`、`rp`）不列入比對。

| 測試書 | 格式 | 方向 | 章節檔 | 頁數 | 各檔「每頁可見＝全文」 | 段落標記 |
|---|---|---|---|---|---|---|
| zh-vertical.epub | EPUB 3 | 直排、右開 | 3 | 28（10＋9＋9） | 全部相同 | 第１～１２０段依序 |
| zh-vertical.azw3 | KF8 | 直排、右開 | 3 | 28（10＋9＋9） | 全部相同 | 第１～１２０段依序 |
| zh-vertical-joint.mobi | 合併式 MOBI（讀 KF8 部分） | 直排、右開 | 3 | 28（10＋9＋9） | 全部相同 | 第１～１２０段依序 |
| ja-vertical.epub | EPUB 3（日文） | 直排、右開 | 2 | 12（6＋6） | 全部相同 | （日文書沒有此標記） |
| zh-horizontal.epub | EPUB 3 | 橫排、左開 | 3 | 23（8＋7＋8） | 全部相同 | 第１～１２０段依序 |
| zh-horizontal.azw3 | KF8 | 橫排、左開 | 3 | 24（8＋8＋8） | 全部相同 | 第１～１２０段依序 |
| zh-horizontal-mobi6.mobi | MOBI 6 | 橫排、左開 | 3 | 27（9＋9＋9） | 全部相同 | 第１～１２０段依序 |
| text-with-images.epub | EPUB 3（圖文） | 橫排、左開 | 2 | 15（9＋6） | 全部相同 | 第１～６０段依序 |
| text-with-images-mobi6.mobi | MOBI 6（圖文） | 橫排、左開 | 2 | 17（10＋7） | 全部相同 | 第１～６０段依序 |
| epub2-ncx.epub | EPUB 2 | 橫排、左開 | 2 | 4（2＋2） | 全部相同 | 第１～２０段依序 |

- 直排三種格式（EPUB、AZW3、合併式 MOBI）的頁數與各檔字數完全相同（1840／1807／1832 字），表示 KF8 重建出的內容與原 EPUB 一致。
- 直排第 1 頁左半留白：下一個元素是插圖，放不進剩下的空間（插圖設為不可跨頁），所以移到第 2 頁（截圖 `04-vertical-first-page.png`、`05-vertical-figure-page.png`，拍攝時系統列隱藏的修正還沒加入）。屬預期行為。
- 表中 EPUB、AZW3、合併式 MOBI 的結果，是在第 4 節第 4、7、8、9 項修正之前的版本取得；這幾項只影響 MOBI 6 的空白段落、重新排版、工具列與說明畫面。最終版本另外重跑了兩本 MOBI 6 與直排 EPUB（表中 MOBI 6 兩列即最終版本的結果；直排 EPUB 在最終版本的結果與先前相同：3 個章節檔、28 頁、全部相同）。修正前的 MOBI 6 多一個 0 字的空白頁（橫排書 28 頁、圖文書 18 頁）。
- 每本書翻到最後一頁後再按「下一頁」，位置不再前進（App 顯示「已到本書結尾」提示；提示文字本身沒有自動擷取）。

### 3.3 其他情境

【已查證】每個情境都先強制停止 App，再從漫畫閱讀器的入口冷啟動（截圖在 `screenshots/stage2/`）。

| 情境 | 結果 |
|---|---|
| 漫畫 CBZ（`comic-pages.cbz`） | 留在既有的漫畫閱讀器，正常顯示第 1／3 頁 |
| 漫畫型 EPUB（固定版面、流動版面各一本） | 我們的判定為「漫畫」，交給既有的漫畫閱讀器；**既有閱讀器回報「No pages found」並關閉**。原因是上游既有問題，見第 6 節。我的改動沒有碰到這段程式，行為與上游相同 |
| DRM：Adobe ADEPT 的 EPUB | 文字閱讀器顯示「This book is protected by DRM／Protection: Adobe ADEPT」與說明，沒有當機（截圖 `case-drm-epub.png`） |
| DRM：加密旗標的 MOBI | 同上，「Protection: Mobipocket / Kindle」（截圖 `case-drm-mobi.png`） |
| 損毀的 EPUB（截斷的檔案、副檔名是 .epub 的非 EPUB 檔） | 我們的解析器判定為損毀後，照設計交回既有閱讀器（維持上游行為）；上游顯示「Unrecognized archive format」提示後關閉，沒有當機 |
| 翻頁鍵、方向鍵 | PAGE_DOWN 下一頁、PAGE_UP 上一頁；直書時 DPAD_LEFT 為下一頁 |
| 音量鍵 | 既有選項「音量鍵翻頁」預設關閉時，按音量鍵不翻頁（選項開啟的情況沒有測） |
| 外部連結 | 跳出「Open this link in the browser?」對話框，顯示網址 `https://example.com/`，有「Cancel」與「Open in browser」（截圖 `link-external-dialog.png`）；按 Cancel 後留在原頁。沒有測按下「Open in browser」（模擬器為飛航模式） |
| 跨章連結 | `ch02.xhtml#p2` 正確開啟第二章並停在目標段落所在的第 1 頁 |
| 旋轉 | 從第一章第 5／10 頁（第 531～755 字）轉成橫向 → 第 3／8 頁（383～616 字，包含第 531 字）；轉回直向 → 回到同一頁（531～755 字）；再來回一次結果相同（截圖 `rotated-landscape-mid.png` 為其中一次的橫向畫面）。修正前，轉回直向會往前偏一頁（第 4 節第 7 項） |
| Firebase（執行期） | logcat：「Default FirebaseApp failed to initialize because no default options were found」「FirebaseApp initialization unsuccessful」 |
| 請求過濾 | logcat 只出現 2 次被拒的請求，都是 WebView 自動要求的 `/favicon.ico`（不在允許的路徑內，回 404） |

---

## 4. 過程中發現並修正的問題

【已查證】每一項都先重現、修正後重跑對應測試。

| # | 問題 | 原因 | 處理 |
|---|---|---|---|
| 1 | 直排 AZW3 被判成橫排 | Calibre 對每本「右開且沒有指定書寫方向」的 KF8 都在 EXTH 525 填 `horizontal-rl`，只為了讓 Kindle 照右開翻頁（Calibre 原始碼 `ebooks/mobi/writer8/mobi.py` 第 225–229 行），書的 CSS 其實是直排 | 以實際套用在 `html`／`body` 的 CSS 為優先；metadata 只採信「vertical」；加 6 個單元測試 |
| 2 | MOBI 6 內容可能被吃掉 | 清理器一律用 XML 解析，Calibre 的 MOBI 6 用 `<img recindex=…>`、`<br>` 這種不閉合寫法，後續內容會被包進 `<img>` | `text/html` 文件改用 HTML 解析器；加單元測試 |
| 3 | MOBI 6 沒有段落縮排 | MOBI 6 以 `<p width="1em" height="11pt">` 表示首行縮排與段前空白，瀏覽器不認得 | 轉成 `text-indent` 與段前空白（使用邏輯屬性，直排時方向正確）；加單元測試 |
| 4 | MOBI 6 最後多一個空白頁 | 最後一個分頁符號後只剩空的 `<a>` | 略過沒有文字也沒有圖片的段落；加單元測試 |
| 5 | 翻頁鍵、方向鍵沒有作用 | 取得焦點的 WebView 先吃掉按鍵 | 在 `dispatchKeyEvent` 先處理；WebView 設為不可取得焦點 |
| 6 | 進入閱讀器時系統列沒有隱藏 | 在 `onCreate` 隱藏，Android 8 上沒有生效 | 視窗取得焦點時再套用一次 |
| 7 | 來回旋轉後位置往前偏一頁 | 每次重新排版都以「目前這頁的第一個字」為準，橫向那頁的第一個字比原本的早 | 改為沿用「上次翻頁時那頁的第一個字」，直到使用者再翻頁 |
| 8 | DRM 說明畫面的返回箭頭看不見 | 箭頭圖示是白色，淺色主題下與背景同色 | 依主題著色 |
| 9 | 說明畫面上按返回鍵沒有離開 | 返回鍵先收起標題列，而說明畫面的標題列一直顯示 | 說明畫面上返回鍵直接離開 |

---

## 5. 沒有驗證或還沒做的部分

- **實機**：沒有測試（此環境沒有實機）。只在 Android 8.0 模擬器、WebView 69 上驗證；較新的 WebView 沒有在本階段測試。
- **閱讀位置、已讀、閱讀紀錄、追蹤**：屬於階段 5。目前重新開啟會從頭開始，也還不會更新章節的 `last_page_read`、已讀狀態與閱讀紀錄。
- **排版設定、雙欄、目錄與進度滑桿、翻頁動畫**：屬於後續階段，本階段沒有做。
- **文字書／漫畫的手動切換**（第 7 題）：還沒做；自動判定的結果目前只存在記憶體，App 重開後第一次開啟 EPUB 會再判定一次（會先短暫進入漫畫閱讀器再切換）。
- **滑動翻頁、音量鍵翻頁**：已實作，但沒有在模擬器上測試滑動，也沒有測試「音量鍵翻頁」選項開啟時的情況。
- **直排注音位於頁首行**：第 1 階段發現 WebView 69 會把頁首行的注音畫到前一頁；本階段逐字比對排除了注音，沒有重新檢查這個問題（預計在階段 4 處理）。
- **由右至左的橫排文字**（阿拉伯文、希伯來文）：沒有處理，橫排一律左開。
- **MOBI 6 目錄**：只讀 guide 中的 `toc` 參照；測試書沒有 guide，所以目錄是空的。MOBI 6 檔內的 NCX 索引還沒有讀取。
- **release 建置與簽章**：等你選擇簽章方式（第 10 題）後再做。目前只有 debug APK。
- **Firebase**：【已查證】`bookmania` 的建置沒有執行 Google Services 與 Crashlytics 任務；APK 的 `resources.arsc` 中沒有 `google_app_id`，所以 FirebaseApp 無法初始化，也就沒有上游 Firebase 專案的設定可用。Firebase 程式庫本身仍在 APK 內（上游程式碼直接引用，移除會動到較多既有檔案）。執行期也確認 FirebaseApp 沒有初始化（見 3.3）。
- **圖示**：仍沿用 Yōkai 的圖示，見第 7 節。

---

## 6. 發現的上游既有問題

### 6.1 以作品 id 開啟詳細頁時當機

【已查證】在模擬器上以 `am start … -a eu.kanade.tachiyomi.SHOW_MANGA --el manga <id>` 冷啟動 App、直接開作品詳細頁時當機一次：

```
kotlin.UninitializedPropertyAccessException: lateinit property chapterSort has not been initialized
  at eu.kanade.tachiyomi.ui.manga.MangaDetailsPresenter.applyChapterFilters(MangaDetailsPresenter.kt:364)
  at eu.kanade.tachiyomi.ui.manga.MangaDetailsPresenter.getChapters(MangaDetailsPresenter.kt:306)
  …
  at eu.kanade.tachiyomi.ui.manga.MangaDetailsPresenter.onCreate(MangaDetailsPresenter.kt:196)
```

- 堆疊中的檔案我都沒有修改。【推論】依程式碼，`onCreate()` 在 `runBlocking` 中呼叫 `setCurrentExcludedScanlators()` → `asyncUpdateMangaAndChapters()` → `getChapters()`，此時 `chapterSort` 還沒在 `syncData()` 中設定。App 已開啟時送同樣的指令沒有當機，所以觸發條件還不完全清楚。
- **沒有**在未修改的上游版本上重現，所以不能確定是上游既有問題。
- 這不在本次任務範圍，我沒有修改；已另外建立一個建議任務（「Fix chapterSort crash when manga details open by id」），由你決定是否處理。
- 本次測試因此改用一般的介面操作開啟作品，不再使用這個指令。

### 6.2 既有漫畫閱讀器打不開 EPUB（「No pages found」）

【已查證】上游 `core/archive/.../EpubReader.kt` 用 jsoup 的 **HTML** 解析器讀 OPF。我在 JVM 單元測試環境（版本目錄中的 jsoup 1.23.2，與 App 相同）重現它的步驟（暫時的測試，已刪除）：OPF 裡的 `<item …/>` 自我閉合標籤不被當作結束，第二個 `<item>` 的父元素變成第一個 `<item>`，`manifest > item` 只找到 1 個項目，spine 對不到頁面，所以回傳 0 頁。

- 這段程式與 `EpubPageLoader` 我都沒有修改；本專案的漫畫型 EPUB 行為與上游相同（同樣打不開）。
- 【推論】幾乎所有 EPUB 的 OPF 都用 `<item …/>` 寫法，所以在這個 jsoup 版本下，既有的「以漫畫閱讀器開 EPUB」大多無法使用。我沒有在未修改的上游 APK 上重現。
- 修正方式很小（OPF 改用 XML 解析器），但要改上游檔案。要不要在本專案修正，請你決定（第 7 節）。

---

## 7. 需要你處理或決定的事

1. **推送到 GitHub**：N09527/bookmania 仍回應 403（「Claude doesn't have GitHub access to N09527/bookmania」）。請到 https://claude.ai/connect-github 連結（或重新連結）GitHub 帳號，並在同一頁把 Claude GitHub App 安裝到這個存放庫。之前的提交都保留在本機分支 `ebook-reader/stage1-design`。
2. **APK 簽章（第 10 題）**：尚未選擇（a 我產生新金鑰交給你／b 你提供 keystore／c debug 簽章）。
3. **套件名稱**：你回覆「可以？」，我目前使用 `io.github.n09527.bookmania`。若要改，請告訴我。
4. **App 圖示**（新問題）：目前沿用 Yōkai 的圖示。Apache-2.0 第 6 條不授權使用上游的商標與產品名稱；圖示是否算在內我無法確定。要換成新圖示嗎？若要，請提供圖檔，或告訴我可以先用簡單的文字圖示代替。
5. **仍待確認**：長條（webtoon）模式不提供捲曲動畫；直向翻頁模式的捲曲從下緣往上；第 5.6 節設定表的範圍與預設值。
6. **上游的兩個既有問題**（第 6 節）：要不要在本專案修正？兩者都需要修改上游檔案（各約 1～5 行），會增加日後合併上游更新時的衝突機會。
7. **架構（第 1 階段新增的 C 題）**：沒有收到回覆，我照建議使用獨立的 `EbookReaderActivity`。若你希望文字書與漫畫共用同一個閱讀畫面，請告訴我。

### 7.1 決定紀錄（2026-11-19，使用者回覆）

| 項目 | 使用者的決定 | 後續 |
|---|---|---|
| GitHub 推送 | 已開通 | 分支 `ebook-reader/stage1-design` 已推送 |
| APK 簽章（第 10 題） | A | 在此環境產生新金鑰簽章 release 版，金鑰檔與密碼交給使用者保管 |
| 套件名稱 | 保持 `io.github.n09527.bookmania` | 定案 |
| App 圖示 | 換掉 | 沒有附圖檔，新圖示的樣式**待確認** |

### 7.2 簽章版 release（2026-11-19）【已查證】

- 金鑰：PKCS12、RSA 4096、別名 `bookmania`、憑證 `CN=Bookmania`（不含個人資料），有效至 2054-04-06。憑證 SHA-256：`E7:60:EA:64:56:C7:C0:08:2F:77:BA:D0:FA:37:28:DC:BD:D5:26:6C:2D:48:84:E6:AE:81:F9:DF:12:35:58:9C`。金鑰檔與密碼已交給使用者；在此環境存放於專案資料夾之外，沒有進入 git。
- 設定：`app/build.gradle.kts` 從 Gradle 屬性 `bookmaniaStoreFile`、`bookmaniaStorePassword`、`bookmaniaKeyAlias`、`bookmaniaKeyPassword` 讀取（例如放在 `~/.gradle/gradle.properties`）；沒有設定時 release 照舊產生未簽章 APK，debug 版照舊用 debug 金鑰。
- `./gradlew :app:assembleBookmaniaRelease`：成功（7 分 4 秒），產出 arm64-v8a 28.9 MB、armeabi-v7a 25.5 MB、x86 30.7 MB、x86_64 31.6 MB、universal 68.6 MB；`apksigner verify` 通過（v2 簽章，minSdk 26 不需要 v1），簽署者 `CN=Bookmania`，SHA-256 與金鑰相符；套件 `io.github.n09527.bookmania`；建置中沒有任何 Google Services／Crashlytics 任務。
- 模擬器實測 release 版（經 R8 縮減、不可除錯）：從首次使用導覽開始（選資料夾用系統的資料夾選擇器），Local Source 開啟直排 EPUB、橫排 AZW3、合併式 MOBI、MOBI 6 都進入文字閱讀器並可翻頁，DRM 書顯示說明畫面；沒有當機（截圖 `release-vertical-epub.png`、`release-formats.png`）。release 版不能用除錯介面，所以沒有做逐字比對。
- 導覽中的觀察（上游既有行為，未修改）：
  - 首次啟動會跳出「Updated to v1.10.3／What's new in this release」，按下會連到 Yōkai 的更新說明。
  - 導覽的權限步驟把「安裝應用程式」權限列為必要（上游用於自我更新與擴充套件）。Bookmania 已關閉自我更新。

### 7.3 新圖示草稿

三個原創草稿見 `screenshots/stage2/icon-drafts.png`：A、B 是「翻開的書＋直排文字線」（藍綠／靛藍），C 是「書脊組成的 B 字」（橘）。要換掉的範圍：桌面圖示與 4 種替代圖示、啟動畫面圖示、通知列小圖示；都可在 `bookmania` flavor 以同名資源覆蓋，不改上游檔案。**待使用者選擇或提供圖檔。**
