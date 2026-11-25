# Bookmania iOS 版設計說明（iOS 階段 0）

- 日期：2026-11-25
- 標示：【已查證】＝實際查過或實測；【推論】＝由事實推導、未實測；【決定】＝我在你同意的範圍內自行決定的細節，可以改。

## 範圍

你在 11/25 的要求：

> 我想請你幫我另外改寫產出iOS的版本給iPad及iPhone使用，然後在main下直接多一個iOS的分支，跟APK一起發布，你不用模擬器驗証，上機的驗証我直接在裝置上進行即可。

重述版本：另外寫一個給 iPhone 與 iPad 用的 iOS 版 Bookmania，放在 `main` 分支裡，和 Android 的 APK 一起發布；不需要我在模擬器上驗證，實機驗證由你在裝置上進行。

你以選項決定的事項：

| 項目 | 你的選擇 |
|---|---|
| 「在 main 下多一個 iOS 的分支」 | `main` 裡的 `ios/` 資料夾（同一個分支、同一個發布流程） |
| 安裝方式 | 免費 Apple ID，用電腦重簽：Releases 放未簽章的 IPA，你用 Sideloadly 或 AltStore 簽章安裝 |
| 功能範圍 | 盡量對齊 Android 版 |
| 最低系統版本 | iOS／iPadOS 26（你的裝置是 26 或更新） |

## 1. 前提與限制

### 1.1 安裝【已查證】

- iOS App 必須經過 Apple 簽章才能安裝。用免費 Apple ID 簽的 App 在 7 天後到期，每台裝置最多 3 個這類 App（[Apple：會員方案比較](https://developer.apple.com/support/compare-memberships/)、[Expo 的整理](https://expo.dev/blog/apple-developer-program-explained-free-vs-paid)）。到期後要用電腦重新簽章安裝，App 的資料會保留【推論：重新安裝同一個套件名稱的 App 是覆蓋更新，實機上要確認】。
- 側載的 App 需要在裝置上開啟「開發者模式」（設定 > 隱私權與安全性 > 開發者模式，iOS 16 起），並在「設定 > 一般 > VPN 與裝置管理」信任自己的 Apple ID（[Sideloadly FAQ](https://sideloadly.io/faq)）。這兩步在第一次安裝時做，詳細步驟會寫在第一個 IPA 的說明裡。
- Sideloadly 與 AltStore 都需要一台 Mac 或 Windows 電腦。

### 1.2 建置與驗證【已查證】

- 這個工作環境是 Linux，沒有 Xcode，無法編譯 iOS 的介面程式。
- 我在這裡安裝了 Swift 6.4.3（Linux 版，已用 swift.org 的發布金鑰驗證簽章），可以編譯並測試**不含介面**的核心程式（電子書解析、資料庫、備份格式、設定模型等）。
- 介面程式只能在 GitHub 的 macOS 執行器上編譯：`macos-26` 映像預設 Xcode 26.6，含 iOS 26.5 SDK（[actions/runner-images](https://github.com/actions/runner-images)）。依 GitHub 文件，公開存放庫使用標準執行器是免費的。
- 我無法讀取 Actions 的執行記錄（這個環境的代理擋下 Actions 的 API）。我會試著從提交的檢查結果（check runs）讀到編譯錯誤；如果也讀不到，編譯錯誤就要請你把 Actions 頁面上的訊息貼給我。
- 你說不需要模擬器驗證。所以介面與實際操作的驗證都在你的裝置上，我這邊只有「核心程式的單元測試」與「GitHub 上編譯成功」兩層。

### 1.3 iOS 沒有的功能【已查證】

- **音量鍵翻頁**：iOS 沒有給一般 App 讀取音量鍵的公開方法，只有相機拍攝專用的介面（[Daring Fireball](https://daringfireball.net/linked/2024/09/06/more-on-spotify-connect-and-iphone-volume-buttons)、[Apple 開發者論壇](https://developer.apple.com/forums/thread/698021)）。
- **線上來源的擴充套件**：Android 的擴充套件是 Android 程式（APK），iOS 無法執行。

## 2. 功能對照（Android → iOS）

### 2.1 納入

| 功能 | iOS 的做法 |
|---|---|
| 本機來源 | App 的「文件」資料夾開放給「檔案」App（我的 iPhone > Bookmania），裡面的 `local/作品資料夾/章節檔案` 結構與 Android 相同；支援 `cover.jpg`、`ComicInfo.xml`、`details.json`。也可以從「檔案」App 匯入。 |
| 書櫃 | 分類、排序、篩選、搜尋、格狀／清單、未讀數量。 |
| 作品頁 | 封面、「內容簡介」、「共 N 冊」、章節清單、已讀／未讀、書籤、排序。 |
| 文字閱讀器 | Android 第 2～8 階段的全部：EPUB、MOBI、AZW3；直排與橫排；翻頁方向；雙欄與中縫陰影；排版設定（三層、字型匯入、數值輸入、粗體）；注音；翻頁動畫（捲曲、滑動、無）；目錄、全書進度滑桿、章節面板；閱讀位置；點擊區；DRM 與損毀檔案的說明。 |
| 漫畫閱讀器 | 本機的 CBZ／ZIP、圖片資料夾、圖片型 EPUB；左右翻頁與直向；捲曲翻頁；雙頁與中縫陰影。 |
| 最新、閱讀紀錄 | 新加入的章節、閱讀紀錄。 |
| 備份與還原 | 與 Android 的備份檔（`.tachibk`）互通：書櫃、分類、章節的已讀與書籤、閱讀紀錄、文字書的閱讀位置（欄位 20101）。書檔本身不在備份裡（與 Android 相同）。 |
| 設定 | 外觀、書櫃、閱讀、資料與儲存；無痕模式；統計；關於、開源授權。 |

### 2.2 不納入

| 功能 | 原因 |
|---|---|
| 線上來源、擴充套件、下載、來源遷移、WebView 登入 | 擴充套件是 Android 程式，iOS 無法執行（1.3）。 |
| 音量鍵翻頁 | iOS 沒有公開方法（1.3）。 |
| 追蹤服務（AniList、MyAnimeList 等） | 【推論】Android 版的登入設定是 Yōkai 註冊的用戶端，iOS 版要用就得另外向各服務申請；Android 版也從未驗證過。你在 11/25 同意不做（第 7 節第 1 項）。 |
| App 內更新、圖示切換、Android 專屬的開發工具 | 與 Android 版相同不做，或 iOS 沒有對應功能。 |

另外遵守原本的約束：不處理 DRM、不加入你沒提出的電子書功能（書內搜尋、劃線、朗讀、字典、線上書庫、雲端同步）、不送出當機報告或分析資料。

## 3. 架構

```
ios/
  project.yml              XcodeGen 的專案設定（Xcode 專案在 GitHub 上產生，不放進存放庫）
  BookmaniaCore/           Swift 套件：不含介面，在 Linux 與 iOS 都能編譯
    Sources/BookmaniaCore/ 電子書解析、ZIP、資料庫、本機來源、設定模型、備份格式
    Tests/                 單元測試（用 core/ebook 的測試書）
  Bookmania/               App：SwiftUI 介面，閱讀器用 UIKit 與 WKWebView
```

- **共用排版殼層**：文字閱讀器直接使用 Android 版的 `app/src/main/assets/ebook/`（`reader.html`、`reader.js`），不複製一份。殼層只透過 `window.__reader` 接受原生端的呼叫，並由原生端輪詢 `status()`，WKWebView 用同樣的方式呼叫它【已查證：讀過 reader.js】。
- **書籍內容的隔離**：書與殼層由 App 自訂的網址協定提供（WKURLSchemeHandler），不讀取一般檔案路徑；書的文件放在沒有腳本權限的 iframe（沿用殼層的 sandbox 與 CSP），另外用 WKContentRuleList 擋掉所有對外連線。解析時沿用 Android 的清理規則（移除 script 等元素與 on* 屬性）。
- **電子書解析**：把 `core/ebook`（Kotlin，約 2,500 行）逐檔移植成 Swift，MOBI／AZW3 部分同樣源自 foliate-js（MIT）。不用第三方套件：ZIP 與 deflate 解壓、寬鬆的 XML／HTML 解析、SHA-1 都自己寫，因為 Linux 與 iOS 要用同一份程式。
- **資料庫**：SQLite（iOS 內建；Linux 測試用系統的 libsqlite3），自己的資料表結構，不必與 Android 相同；兩邊靠備份檔互通。
- **第三方元件與授權**：App 不含第三方程式庫。建置工具 XcodeGen（MIT）只在 GitHub 上使用，不會包進 App。SQLite 為公有領域。foliate-js 的 MIT 聲明沿用。
- **版本**：iOS 與 Android 用同一個版本號（`app/build.gradle.kts` 的 `_versionName` 與 `versionCode`），發布流程把它帶入 iOS 的版本設定。
- **套件名稱**：`io.github.n09527.bookmania`（側載工具有時會改掉它，不影響使用）。

## 4. 階段

每個階段結束時會有一份報告，並在 Releases 發布一個新版本，和 APK 一起附上可以安裝的未簽章 IPA（你在 11/25 的決定，見第 7 節）。

| 階段 | 內容 | 你在裝置上驗證 |
|---|---|---|
| iOS-1 | 核心解析移植與測試；App 骨架（分頁、圖示、正體中文／英文）；本機來源與書櫃清單；作品頁；最小文字閱讀器（單欄、預設排版、實體鍵盤翻頁）；GitHub 的建置與 IPA；Releases 附上 IPA | 側載流程、開書、翻頁 |
| iOS-2 | 排版設定（三層、字型匯入、數值輸入、粗體）、翻頁方向、雙欄與中縫陰影 | 各項排版 |
| iOS-3 | 閱讀位置、已讀、閱讀紀錄、目錄、進度滑桿、章節面板、翻頁動畫、點擊區 | 閱讀流程 |
| iOS-4 | 書櫃功能（分類、排序、篩選、搜尋）、最新、閱讀紀錄頁、無痕模式、設定、統計、關於 | 書櫃與設定 |
| iOS-5 | 漫畫閱讀器（CBZ、圖片資料夾、圖片型 EPUB、捲曲、雙頁中縫陰影） | 漫畫 |
| iOS-6 | 與 Android 互通的備份與還原；整體回歸 | 備份互通 |

【推論】這是和 Android 第 2～8 階段加總相當的工作量。介面程式只能在 GitHub 上編譯，每次修正都要等一輪建置，所以每個階段需要的時間會比 Android 版長。

## 5. 驗證方式

1. **單元測試（Linux，這裡）**：核心程式。電子書解析沿用 Android 的測試書與預期結果，兩邊的行為要一致。
2. **編譯（GitHub macOS）**：每次推送後建置 App 與 IPA。
3. **實機（你）**：每個階段報告會列出要在裝置上檢查的項目與步驟。沒有在實機上確認的項目，我在報告裡照實標示。

## 6. 風險

- **看不到畫面寫介面**：介面程式在這裡無法編譯或執行，錯誤要靠 GitHub 的建置與你的實機回報發現。
- **WebKit 與 Android WebView 的差異**：殼層是在 Android WebView 上調整的；iOS 的 WebKit 對直排、多欄、注音的處理可能不同，要在實機上確認。
- **免費 Apple ID 的限制**：每 7 天要重簽；每台裝置最多 3 個這類 App。

## 7. 待確認與你的回覆

我問的四個問題：

1. **追蹤服務**：同意先不做嗎？（2.2）
2. **音量鍵的替代**：iPad 接實體鍵盤時，用方向鍵與空白鍵翻頁，要加嗎？
3. **測試版的取得方式**：測試版 IPA 放在 GitHub Actions 的執行結果，正式版才進 Releases，這樣可以嗎？
4. **第一個帶 IPA 的正式版本**：iOS 版完成所有階段之前，Releases 只放 APK，這樣可以嗎？

你在 11/25 的回覆：

> 1. 可以嗎？ 2. 加方向鍵翻頁 3. 直接release我測試 4. 直接release我測試

> 1.可以

| 項目 | 結果 |
|---|---|
| 1. 追蹤服務 | **不做**。重述版本：你同意 iOS 版先不做追蹤服務（第二次的回覆「1.可以」）。 |
| 2. 實體鍵盤翻頁 | 加入，按鍵與 Android 版相同：左右方向鍵依翻頁方向（直排、右開的書按左鍵是下一頁），空白鍵與 Page Down 是下一頁，Page Up 是上一頁；上下方向鍵不翻頁（Android 版也不翻）。上方與下方的列顯示時不翻頁（同 Android）。 |
| 3、4. 測試版的取得方式 | 測試版直接在 Releases 發布，和 APK 放在同一個版本，從 1.1.0 開始。每次推送的 IPA 仍會留在 Actions 的執行結果，供兩次發布之間使用。 |
