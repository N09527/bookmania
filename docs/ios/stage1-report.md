# Bookmania iOS 階段 1 報告：核心解析、App 骨架與最小文字閱讀器

- 日期：2026-11-25
- 分支：`ebook-reader/stage1-design`（之後併入 `main`）
- 標示：【已查證】＝本次實際執行或實測；【推論】＝由事實推導、未實測；【決定】＝我在你同意的範圍內自行決定的細節，可以改。
- 設計說明：[docs/ios/design.md](./design.md)；安裝步驟：[docs/ios/INSTALL.md](./INSTALL.md)。

## 0. 摘要

- **核心解析**：Android 的 `core/ebook`（約 2,500 行 Kotlin）逐檔移植成 Swift 套件 `ios/BookmaniaCore`，可在 Linux 與 iOS 編譯。Android 的 41 個單元測試全部移植，用同一批測試書、同樣的預期值；加上新的測試，共 50 個，在這裡（Linux）全部通過【已查證】。
- **App**：四個分頁（書櫃、最新、探索、其他）、本機來源（「檔案」App 裡的 `Bookmania/local`，結構與 Android 相同）、作品頁（內容簡介、共 N 冊）、關於與開放原始碼授權、正體中文與英文。
- **文字閱讀器**：直接使用 Android 的排版殼層（`reader.html`、`reader.js`），在 WKWebView 中排版；點擊左右三分之一或滑動翻頁、章節之間接續、中間點擊顯示書名與頁碼；DRM、損毀、KFX 檔案顯示與 Android 相同的說明。
- **建置**：GitHub Actions 的 `iOS` 工作流程在 Linux 跑核心測試、在 macOS 26（Xcode 26.6）建置未簽章的 IPA。這一階段推送的 5 次建置全部成功【已查證】；最後一次的 IPA 約 467 KB，App 內容檢查通過（第 5 節）。
- **沒有驗證的**：App 的介面與閱讀器都還沒有在實機或模擬器上執行過（第 5 節）。這一版要請你在 iPhone 與 iPad 上試。

## 1. 核心解析（BookmaniaCore）

| Android（Kotlin） | iOS（Swift） | 備註 |
|---|---|---|
| `io/ZipReader.kt`（`java.util.zip`） | `IO/ZipReader.swift`、`IO/Inflate.swift` | Deflate 解壓自己寫（Linux 與 iOS 共用），也支援 zlib 與 gzip（之後的備份要用） |
| `epub/EpubParser.kt`、`FontObfuscation.kt` | `Ebook/Epub/` | SHA-1 自己寫（字型反混淆用） |
| `mobi/*.kt`（源自 foliate-js） | `Ebook/Mobi/*.swift` | 保留 foliate-js 的 MIT 聲明 |
| `XhtmlSanitizer.kt`、`WritingModeDetector.kt` 等（Jsoup） | `Markup/Markup.swift`、`Markup/CSSSelector.swift` 等 | Jsoup 沒有跨平台的 Swift 版本，所以寫了寬鬆的 XML／HTML 解析器與簡單的 CSS 選擇器比對 |
| `font/FontInspector.kt` | `Font/FontInspector.swift` | |

- App 不含任何第三方程式庫【已查證：Package.swift 沒有相依】。
- 【決定】字數統計與 Android 一樣以 UTF-16 單位計算、用 Kotlin 的空白定義，所以三種格式的字數與 Android 相同（測試：zh-vertical 三章 1880／1847／1872）。
- 新增：`LocalLibrary`（本機來源的作品與章節，規則同 Android：章節網址「作品資料夾/檔名」、自然排序、`cover.jpg`、ComicInfo.xml 優先於 details.json）、`ReaderURLs`（閱讀器的網址與 CSP）、`ShellSettings`（傳給殼層的設定）、`EbookSettings`（排版設定模型，三層覆寫，值與 Android 相同；階段 2 用）。

## 2. App

- 分頁：書櫃（本機的所有作品；「加入書櫃」與分類在 iOS-4）、最新（閱讀紀錄在 iOS-3）、探索（只有本機來源，附放書的說明）、其他（關於、版本、原始碼、開放原始碼授權）。
- 檔案：`Info.plist` 開啟 `UIFileSharingEnabled` 與 `LSSupportsOpeningDocumentsInPlace`，App 的「文件」資料夾會出現在「檔案」App；第一次打開時建立 `local` 資料夾。
- 圖示：Android 圖示的設計，1024 px 滿版不透明（iOS 自己加圓角）。
- 介面文字：用語跟 Android 正體中文版一致（書櫃、最新、探索、其他、本機來源、內容簡介、共 N 冊、沒有簡介、開放原始碼授權）。

## 3. 文字閱讀器

- 殼層：`project.yml` 直接把 `app/src/main/assets/ebook` 放進 App，兩邊共用同一份檔案【已查證：reader.js 透過 `window.__reader` 由原生端呼叫並輪詢 `status()`，沒有用到 Android 專屬的介面】。
- 書籍內容的隔離（與 Android 相同的原則）：
  - 自訂網址 `bookmania://reader/` 只提供殼層兩個檔案、這本書的資源（文件先清理並加 CSP）、以 id 指定的匯入字型；其他一律拒絕（單元測試涵蓋）。
  - WebKit 內容規則封鎖所有載入，只放行 `bookmania://reader/`、`data:`、`about:`。
  - 不保存網站資料；書的 iframe 不接受觸控（所有操作由原生端處理）。
  - 【決定】CSP 除了 `'self'` 也列出 `bookmania:`，以防 WebKit 不把自訂協定視為同源；這個協定只回應上面列的路徑，所以範圍相同。
- 操作：點擊左／右三分之一翻頁（依書的方向，直排右翻左），左右滑動翻頁，中間點擊顯示上方的關閉與書名、下方的「頁數／總頁數　檔案序號／檔案數」；一個檔案的最後一頁再往後，接下一個檔案。
- 外觀：跟隨系統的淺色／深色（深色用 Android 閱讀器的 rgb(32,33,37) 與 #E0E0E0）。
- 預設排版：與 Android 的預設值相同（字級 20、行距 1.8、上下邊距 32、左右 20、橫向畫面時雙欄）。

## 4. 建置與發布

- `.github/workflows/ios.yml`：推送到任何分支、而且改到 `ios/`、殼層或測試書時執行。
  - 核心測試（Ubuntu 24.04，Swift 6.4.2）。
  - App：`xcodegen generate` 產生專案，`xcodebuild` 以 Release 設定、不簽章建置，打包成 `Bookmania-unsigned.ipa`，放在執行結果的 Artifacts（名稱 `Bookmania-ios-unsigned`）。
  - 編譯錯誤會寫成標註（annotation），我可以從這裡讀到，不必請你貼記錄【已查證：第一次建置後讀到了標註】。
- 版本號沿用 `app/build.gradle.kts`（目前 1.0.0、內部編號 200）。
- 正式發布（Releases 放 IPA）：等你回覆設計說明第 7 節第 4 項；目前 `release.yml` 沒有改。

## 5. 驗證

【已查證】

- **這裡（Linux，Swift 6.4.3）**：BookmaniaCore 的 55 個單元測試全部通過（16 組：路徑、格式判斷、ZIP、Deflate／SHA-1、內容清理、EPUB、字數、MOBI／AZW3、直排判定、字型檢查、本機書庫、閱讀器網址、排版設定、設定儲存、字型儲存、書目讀取）。
- **GitHub（Ubuntu 24.04，Swift 6.4.2）**：同樣的核心測試，每次推送都通過。
- **GitHub（macOS 26，Xcode 26.6，iOS 26.5 SDK）**：App 每次都編譯成功（介面與閱讀器的程式第一次推送就通過，沒有需要修正的編譯錯誤）。最後一次（提交 `476d90a`，[執行結果](https://github.com/N09527/bookmania/actions/runs/45658297049)）：
  - IPA：`Bookmania-unsigned.ipa`，477,900 bytes，SHA-256 `d3d874899d328064f08c01e136149783152752f36308231e9d79b79021b46216`。
  - App 內容檢查：版本 1.0.0（200）、最低 iOS 26.0、arm64；排版殼層兩個檔案、兩份授權聲明、資源目錄、英文與正體中文字串都在。
  - 每次建置的 IPA 雜湊值都不同（壓縮檔內的時間不同），大小相同。

沒有做的：在模擬器或實機上執行 App（你說不需要模擬器；實機由你進行）。

## 6. 請你在裝置上檢查

先照 [INSTALL.md](./INSTALL.md) 安裝。書可以用你自己的、沒有 DRM 的 EPUB、MOBI、AZW3。

1. **安裝與啟動**：主畫面的圖示與名稱是 Bookmania；打開後有四個分頁。
2. **檔案 App**：「我的 iPhone（我的 iPad）> Bookmania > local」存在；在 `local` 建一個作品資料夾、放書，回到 App 的書櫃下拉重新整理，作品出現。
3. **作品頁**：顯示「內容簡介」（沒有就是「沒有簡介」）與「共 N 冊」，列出書檔。
4. **閱讀**：直排與橫排各開一本，文字是否照書的方向排版（直排由右往左）；點擊左右、左右滑動翻頁；讀到一個檔案的最後一頁再往後，是否接下一個檔案。
5. **雙欄**：iPad 橫放（或 iPhone 橫放）時是否變成兩欄。
6. **旋轉與深色模式**：閱讀中旋轉、切換深色模式，版面是否重新排好。
7. **錯誤處理**：放一個受 DRM 保護或壞掉的檔案，打開時是否顯示說明而不是閃退。
8. **關閉**：點中間，左上角的 ✕ 關閉閱讀器。

有問題時，請告訴我是哪一項、哪台裝置與系統版本，最好附上截圖。

## 7. 這一版沒有的（之後的階段）

- 排版設定面板、字型匯入、翻頁方向設定（iOS-2）。
- 閱讀位置、已讀、閱讀紀錄、目錄、進度滑桿、章節面板、翻頁動畫（iOS-3）。
- 加入書櫃與分類、排序、搜尋、設定頁、無痕模式、統計；章節名稱改用書內的書名、作品封面取自書檔（iOS-4）。
- 漫畫閱讀器（iOS-5）、與 Android 互通的備份（iOS-6）。

## 8. 沒有驗證的項目

- App 從未在實機或模擬器上執行；介面、閱讀器、檔案 App 整合、側載流程，都要等你的實機測試。
- WebKit 對殼層的直排、多欄、注音排版是否與 Android WebView 一致。
- CSP 在自訂網址協定下是否生效（書的 iframe 本身沒有 `allow-scripts`，書中腳本無論如何不會執行）。
- 【推論】7 天後重新簽章安裝會保留資料，要在第一次重簽時確認。
