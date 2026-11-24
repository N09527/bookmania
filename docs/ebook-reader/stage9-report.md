# Bookmania 階段 9 報告：成為獨立的 App（存放庫整理）

- 日期：2026-11-24
- 分支：在 `ebook-reader/stage1-design` 上工作；GitHub 上的 `master` 已經快轉到同一個提交，內容就是 Bookmania。改名為 `main` 被這個環境擋下，要請你在網頁上操作（第 4、5 節）。
- 標示：【已查證】＝本次實際執行或實測；【推論】＝由事實推導、未實測；【決定】＝我在你同意的範圍內自行決定的細節，可以改。

範圍：你在 11/24 的要求：

> 因爲有蛮多改写的，然后基本上我们也设计了新的 logo。……现在看起来，我们跟一开始的 fork 的原本 repo 落差还蛮大的，所以想请你帮我把这一个 repo……用符合業內規範的方式……重新整理一下變成一個以 Bookmania 爲主的 repo，然后就是让大家知道我是从 Yokai Fork 来，但是基本上做了改写，现在是一个全新的 App，不再是 yokai 了，就是包含 ReadMe 那些啊都做一些调整。

重述版本：把存放庫整理成以 Bookmania 為主的獨立專案。說明它源自 Yōkai，但已大幅改寫，現在是新的 App，不再是 Yōkai；README 等文件一併調整。

你以選項決定的事項：

| 項目 | 你的選擇 |
|---|---|
| GitHub 的 fork 標示 | 解除 fork 關係（你在網頁設定按「Leave fork network」） |
| 以後要不要合併 Yōkai 的更新 | 完全分家：移除 Yōkai 版的建置、Firebase 與 Yōkai 的發布流程 |
| 預設分支 | 改成 `main`，內容換成 Bookmania |
| Logo | 用 App 現在的圖示（第 2 階段選定的 A 款、橘底） |
| README 的語言 | 正體中文為主，附英文版 |
| 版本號 | 從 1.0.0 重新開始，內部編號從 200 起 |
| 著作權名稱 | N09527 |
| GitHub 功能 | 開啟 Issues；自動發布 release |
| 發布哪一種版本（後來的決定） | debug 版，用固定的 debug 金鑰（「我只要發佈debug版就好，自用而已」） |

---

## 0. 摘要

- **存放庫文件**：README（正體中文）與 README.en.md（英文）、NOTICE、CHANGELOG、CONTRIBUTING、issue 與 PR 範本都改成 Bookmania 的，並寫明源自 Yōkai 的 `843a59b`。Apache-2.0 授權與原有的著作權聲明保留。
- **App**：只剩 Bookmania 一個建置版本；移除 Firebase（當機回報與使用分析）；版本 1.0.0（內部編號 200）。release 版 1.0.0 可以直接覆蓋先前交付的 1.10.3（162），但 Releases 上發布的是 debug 版，它是另一個 App（第 5 節第 6 項）。修正一個從第 2 階段就存在的問題：「關於」頁會向 Yōkai 查詢新版本。名稱、圖示、連結換成 Bookmania 的。
- **自動發布**：發布的是 debug 版，用存放庫裡的 debug 金鑰簽章，不需要任何 secrets。`main` 上的版本號改變時自動發布，也可以在 Actions 分頁手動執行。**這個工作流程還沒有在 GitHub 上實際跑過**（第 7 節）。
- **驗證**【已查證】：三組單元測試在最終程式上全部通過（:app 73、:core:ebook 41、:domain 34）；release 版與 debug 版都在模擬器上安裝並檢查過；發布工作流程的每個 shell 步驟都在本機模擬過。
- **被這個環境擋下的 GitHub 操作**（HTTP 403，依規定沒有繞道）：推送標籤、把分支改名、修改存放庫設定（開啟 Issues）、讀寫 Actions 設定。所以「解除 fork」「master 改名 main」「開啟 Issues」「啟用 Actions 與第一次發布」要請你在網頁上做，步驟在第 5 節。

---

## 1. 存放庫

### 1.1 README、NOTICE 與授權

- `README.md`（正體中文）與 `README.en.md`（英文），互相連結。內容：
  - Logo：App 的圖示轉成 SVG 與 PNG（`.github/readme-images/bookmania-logo.svg`、`.png`）。
  - 三張截圖：直排雙欄、橫排雙欄、排版面板。取自先前階段的模擬器截圖，書是自製的測試書。
  - 功能（依各階段報告整理）、安全與隱私、沿用自 Yōkai 的功能、下載、從原始碼建置、由來、開發紀錄、參與、免責聲明、授權。
- 由來：寫明從 Yōkai 的 commit `843a59b`（當時版本號 1.10.3）分出，Yōkai 本身源自 TachiyomiJ2K 與 Tachiyomi；致謝；與 Yōkai、Tachiyomi、Mihon 沒有隸屬關係，名稱只用來說明來源。
- 授權：`LICENSE`（Apache-2.0 全文）沒有改。README 的授權段保留原本的兩行著作權（Javier Tomás 2015、null2264 2024），加上「Copyright © 2026 N09527」。
- 新增 `NOTICE`：保留 Yōkai 的著作權聲明，說明 Bookmania 改了什麼、怎麼列出改過的 Yōkai 檔案，以及以原始碼形式納入的第三方程式 foliate-js（MIT）。

【推論】依 Apache-2.0 第 4 條，散布修改後的版本要附上授權、保留原有的著作權聲明，並標示修改過的檔案。這次以 NOTICE 的說明加上 git 紀錄標示修改；第 2～8 階段修改的上游檔案，多數也在修改處加了 Bookmania 的註解。我不是律師，這是依授權條文的一般做法。

### 1.2 變更紀錄、貢獻指南與範本

- `CHANGELOG.md`：改成 Bookmania 的變更紀錄，從 1.0.0 開始。分出來之前的變更，連到 Yōkai 在分叉點提交 `843a59b` 的變更紀錄（永久連結）。
  - 原本打算建立標籤 `yokai-fork-point` 標示分叉點，但這個環境不能推送標籤（第 4 節），所以改用提交的永久連結。【已查證】這個連結在 GitHub 上回應 200。
- `.github/CONTRIBUTING.md`：正體中文為主，附英文摘要。包含回報方式、建置、程式碼位置，以及原則：書籍內容不可信、不加入移除 DRM 的功能、授權相容、migration 只新增等。
- issue 範本：「回報問題」與「功能建議」兩種，中英並列。回報問題要填 App 版本、Android 版本與 WebView 版本。
- PR 範本：中英並列，附檢查清單。

### 1.3 自動發布（`.github/workflows/release.yml`）

什麼時候執行：

- 推送到 `main` 的變更包含 `app/build.gradle.kts` 時（也就是改了版本號的時候）。
- 或手動：「Actions」分頁 >「Release」>「Run workflow」。

第一步「檢查版本」，任何一項不符就停止、不發布：

1. 只在 `main` 上執行。
2. 讀出 `_versionName` 與 `versionCode`。
3. 這個版本已經發布過：什麼都不做（不算失敗）。
4. 同名的標籤已經存在、但指向另一個提交：停止。
5. `versionCode` 必須比上一個發布的版本大（手機只接受內部編號更大的更新）。

第二步「建置與發布」：

1. 跑三組單元測試，建置 debug 版的五個 APK（arm64-v8a、armeabi-v7a、x86、x86_64、universal）。
2. 逐一驗證簽章，並確認每個 APK 的簽章憑證就是 `app/debug.keystore` 的憑證。
3. 檔名改成 `bookmania-v1.0.0-debug-arm64-v8a.apk` 這種格式，產生 `SHA256SUMS.txt`。
4. 發布說明取自 CHANGELOG 中這一版的段落，加上中英文的下載說明與 SHA-256。CHANGELOG 裡的相對連結（例如 `./docs/ebook-reader`）在發布頁會失效，所以改成指向這個提交的完整網址。
5. 建立標籤 `v<版本>` 與 release。

其他：

- 用到的 GitHub actions 都固定到 commit（checkout v7、setup-java v6、gradle/actions v6），這些版本是 11/24 從各自的存放庫查到的最新主版本。
- 原本的設計是「推送 `v1.2.3` 標籤時發布」。但這個環境推送標籤會被拒絕（第 4 節）；【推論】你以後透過 Claude 的雲端工作階段，多半也推不了標籤。所以改成「`main` 上的版本號改變就發布」，標籤由工作流程在 GitHub 上自己建立【決定】。
- 只從 `main` 發布、只在 `app/build.gradle.kts` 有變更時自動執行，都是【決定】。
- `docs/RELEASING.md` 說明 debug 版與 release 版的差別、每次發布的步驟、手動執行的方法，以及選用的 release 版建置方式。

### 1.4 debug 金鑰（`app/debug.keystore`）

- 依你的選擇，debug 版改用存放庫裡一把固定的 debug 金鑰簽章：PKCS12，別名 `androiddebugkey`，兩個密碼都是 `android`，憑證名稱 `CN=Bookmania Debug`，有效到 2056-11-16。憑證 SHA-256：`2C:B1:01:83:F6:5E:BF:28:49:93:C2:CD:B9:4F:21:24:A2:D9:D2:B3:85:1A:3A:96:CA:57:5B:A4:A4:E1:81:D6`。
- 好處：在這裡、在 GitHub Actions 或別台電腦建置的 debug 版，簽章都相同，新版可以直接覆蓋安裝舊版。
- 代價：這把金鑰是公開的，任何人都能用它簽出可以覆蓋你 debug 版的 APK。只從這個存放庫的 Releases 下載，就不會遇到。
- 私人的 release 金鑰沒有放進存放庫，也從未提交。

### 1.5 移除的 Yōkai 檔案

- README 的圖片：Yōkai 的圖示、截圖動畫，以及 J2K 功能的兩張截圖。
- `.github/FUNDING.yml`：贊助對象是 null2264。
- 工作流程三個：Yōkai 的發布（含發布到 null2264/yokai-nightly）、PR 建置檢查、鏡像到 null2264 的 GitLab。你沒有選「自動建置檢查」，所以沒有新增 PR 建置檢查。
- 舊的 issue 範本「Issue report」：它連到 Mihon 的網站。

## 2. App

### 2.1 建置：只剩 Bookmania

- 移除 Yōkai 版（standard）與 dev 兩個建置版本、beta 與 nightly 兩個發布管道，以及它們的資源，包括 Yōkai 的 Firebase 設定檔 `google-services.json`。
- 只保留 `bookmania` 一個版本，所以建置指令與 APK 檔名不變（`assembleBookmaniaRelease`、`app-bookmania-*.apk`）【決定】。
- 移除 Firebase：Crashlytics 與 Google 服務的外掛、Firebase 程式庫、當機回報的記錄器、「進階」設定的「傳送當機報告」開關，以及 ProGuard 規則。
- 套件名稱寫在預設設定：`io.github.n09527.bookmania`，debug 版加 `.debug`，和先前相同。
- debug 版的簽章改用 `app/debug.keystore`（1.4）；release 版仍然從 Gradle 屬性讀取私人金鑰。
- 版本：1.0.0，內部編號 200（先前的測試版是 1.10.3、162）。

### 2.2 既有問題：「關於」頁會向 Yōkai 查詢新版本

- 【已查證：程式碼】「關於」頁每次打開都會檢查新版本，一天最多一次。這個檢查沒有受「不內建更新」的設定限制，查的是 Yōkai 的 GitHub 發布頁（null2264/yokai）。
- 【推論】Yōkai 發布比 1.10.3 新的版本時，Bookmania 會跳出「有新版本」並提供 Yōkai 的下載連結；在 Android 12 以上，若自動更新的設定不是「永不」，還會自動開始下載。這從第 2 階段就存在，之前沒有發現。版本號改成 1.0.0 之後，Yōkai 目前的版本都會被當成新版。
- 修正：只有在內建更新功能開啟時才檢查（Bookmania 是關閉的）；更新來源改成 N09527/bookmania。

### 2.3 名稱、圖示與連結

- 圖示：Bookmania 的圖示從 `bookmania` 版本的資料夾移到主要資源。Yōkai 與 Tachiyomi 的桌面圖示、商店圖與 debug 圖示刪除。App 先前顯示的就是 Bookmania 的圖示，這次只是不再帶著 Yōkai 的檔案。
- 名稱：字串資源中的 App 名稱（`app_name` 等三個不需翻譯的字串）改為 Bookmania。英文與正體中文裡把 App 叫做「Tachiyomi」的兩句改成 Bookmania：「WebView 為 Bookmania 的必要元件」與大量下載的警告。
- 「關於」頁：
  - GitHub 連到 N09527/bookmania。
  - 「這一版的新功能」連到 CHANGELOG（`main` 分支上的檔案，所以要等分支改名後才連得到，見第 5 節）。
  - 移除 Mihon 網站、Discord 與兩個翻譯連結（Weblate 上是 Yōkai 的翻譯專案）。
- 追蹤服務連線時的 User-Agent 從 `null2264/yokai/版本` 改為 `N09527/bookmania/版本`。
- App 記錄（logcat）的標籤從 Yokai 改為 Bookmania。第 5.5 階段的翻頁檢查腳本依標籤讀取記錄，已一併修改。

### 2.4 說明連結

- 【已查證：11/24 實際連線】tachiyomi.org 的說明都已失效。App 裡有 7 處連到 tachiyomi.org，指向 5 個頁面；這 5 個頁面都回應 301，轉到 github.com/tachiyomiorg。
- 「更多」選單與設定頁的「說明」改連到 Bookmania 的 README【決定】。
- 其他 5 個功能的說明（來源遷移、新增來源、疑難排解、書櫃更新的兩個常見問題）改為 Mihon 網站上相同主題的頁面。我確認過這些頁面都回應 200，標題也相符；用不存在的網址測試會得到「404 | Mihon」，所以不是假的成功頁。
- 原本就連到 Mihon 的 4 個說明（備份、本機來源、儲存空間、Cloudflare）沒有改，它們說明的是沿用自 Yōkai 的功能【決定】。

## 3. 驗證

紀錄（結果、記錄與截圖）在 `docs/ebook-reader/screenshots/stage9/`，檢查腳本在 `docs/ebook-reader/tools/stage9/`。

### 3.1 單元測試【已查證】

在最終的程式（提交 `a9cd0b2`，之後只加了這份報告）上執行，全部通過，沒有略過：

| 模組 | 測試數 | 失敗 |
|---|---|---|
| `:app`（`testBookmaniaDebugUnitTest`） | 73 | 0 |
| `:core:ebook` | 41 | 0 |
| `:domain` | 34 | 0 |

`:core:ebook` 與 `:domain` 第一次被 Gradle 判定為「輸入沒變、沿用舊結果」，我用 `--rerun` 強制重新執行，上表是重跑的結果。這三組就是發布工作流程會跑的測試。

### 3.2 release 版 1.0.0（模擬器，Android 8.0）【已查證】

- APK 由提交 `1004c14` 建置（APK 內記錄的建置資訊：`1.0.0 (bookmania, 1004c14, 200)`）。之後的提交只改了 debug 版的簽章、工作流程與文件，release 版的程式沒有變。
- 套件資訊：版本 1.0.0、內部編號 200、minSdk 26、名稱 Bookmania；簽章憑證是 `CN=Bookmania`，和先前交付的 APK 相同。
- 覆蓋安裝：前一個 release 建置（說明連結修正之前）在裝著 1.10.3（162）的模擬器上直接覆蓋安裝成功，變成 1.0.0（200），書櫃的書還在。最後這個 APK 再覆蓋安裝在 1.0.0 上，也成功，書櫃的書還在。兩者的簽章與內部編號相同。
- 「關於」頁：顯示「Release 1.0.0」；連結只剩 GitHub；沒有翻譯連結；選單項目顯示「About v1.0.0」。
- App 記錄裡沒有 `api.github.com`（不再查詢更新）。
- Firebase：記錄裡出現過 Firebase 的訊息，但都來自另一個行程，也就是當時模擬器上的舊 debug 版（1.10.3，還帶著 Firebase）；release 版的行程沒有任何 Firebase 訊息。
- APK 內容：程式（dex）裡 `firebase`、`null2264/yokai`、`tachiyomi.org`、`discord.gg` 都是 0 筆，`N09527/bookmania` 有 6 筆；沒有 `google-services` 或 Firebase 的檔案。
- 檔案：arm64-v8a 28,193,374 bytes，SHA-256 `3fcfa69297127e5e349a1740bf2caff18eeb5ed64c50d460ee6d13f0193bd9be`；universal 67,830,626 bytes，SHA-256 `7447b89aadfb3fa335e42dbc81c54dac9c5e70e236047269c78853e60a536a45`。這些 APK 只用於測試，沒有另外交付。

### 3.3 debug 版 1.0.0-d129（模擬器）【已查證】

- APK 由提交 `f7bd5bc` 建置（APK 內有這個提交編號），名稱「Bookmania Debug」，用 `app/debug.keystore` 簽章。
- 模擬器上原本的 debug 版是用這台機器自己的 debug 金鑰簽的，新版無法覆蓋，所以先解除安裝再安裝（這只發生在測試環境；先前交付給你的都是 release 版，見第 5 節第 6 項）。
- 測試資料（書櫃、閱讀位置、偏好設定、書檔與封面）從 release 版複製回來，App 語言設回正體中文。
- 作品頁字串檢查（第 8 階段的 `check_stage8.py strings`）4 項全部通過：作品頁出現、簡介標題是「內容簡介」、沒有以「關於此」開頭的標題、章數是「共 5 冊」。
- 四本測試書（直排 EPUB、橫排 EPUB、直排 AZW3、橫排 MOBI 6）都在文字閱讀器開啟、排版完成，按翻頁鍵後頁碼前進一頁。
- 「設定」的備份位置：「Data and storage」（這一項沒有正體中文翻譯，畫面上就是英文）。程式碼裡，它的「備份與還原」區有「建立備份」與「還原備份」兩個按鈕。
- APK 內容：`null2264/yokai`、`tachiyomi.org`、`discord.gg` 都是 0 筆。`firebase` 有 5 筆，來源是 Yōkai 原本就直接依賴的 `com.google.android.gms:play-services-gcm` 17.0.0：它帶進的 play-services-basement 內建 3 個 `com.google.firebase` 例外類別；另外兩筆是 Google 程式庫裡的一段說明文字，以及一個列出 Google 類別的長字串。相依清單裡沒有任何 Firebase 程式庫；release 版經過 R8 縮減後是 0 筆。

### 3.4 發布工作流程（本機模擬）【已查證】

- actionlint 1.7.12 加 shellcheck：沒有任何提示。
- 「檢查版本」這一步，在一份測試用的複本上模擬 7 種情況，分別用 GitHub 預設的 `bash -e` 與 `-eo pipefail` 兩種方式執行，結果都符合預期：
  1. 新版本、沒有任何標籤：發布。
  2. 已經發布過：不發布，不算失敗。
  3. 不在 `main`：停止。
  4. 同名標籤在另一個提交：停止。
  5. 同名標籤在同一個提交：發布。
  6. `versionCode` 沒有比上一版大：停止。
  7. `versionCode` 比上一版大：發布。
  - 模擬時發現一個錯誤並已修正：沒有任何舊標籤時，原本的寫法在 pipefail 模式下會讓這一步失敗（第 1 種情況）。
- 「檢查簽章、收集 APK」：用本機建好的五個 debug APK 執行，全部通過簽章比對，產生正確檔名與 `SHA256SUMS.txt`。
- 「寫發布說明」：取出 CHANGELOG 的 1.0.0 段落，相對連結換成完整網址；沒有對應段落時只出警告。
- 這些模擬都用假的 `gh` 指令代替 GitHub，所以不涵蓋 GitHub 上的部分（第 7 節）。

### 3.5 過程中的問題（如實記錄）

- **建置時記憶體不足**：模擬器開著時建置 release 版，Gradle 被系統以記憶體不足終止（`dmesg` 有紀錄）。關掉模擬器後重建成功。這是這台測試機器的限制，和程式無關。
- **測試環境的資料遺失**：換 debug 版之前，我先把模擬器上舊 debug 版的資料備份成壓縮檔，但關閉模擬器前沒有先把資料寫回磁碟，備份不完整，舊 debug 版的資料已經刪除。我改從 release 版那份副本（13:35 的 release 冒煙測試時從 debug 版複製過去的）重建了測試環境，3.3 的檢查都在重建後的環境上通過。只影響這台模擬器，存放庫與你的手機都沒有受影響。之後關閉模擬器前都先執行 `adb shell sync`。

## 4. GitHub 上的設定

做了的【已查證】：

- `master` 從 `843a59b`（Yōkai）快轉到 Bookmania 的提交；推送成功。這份報告提交後，會再快轉一次到最新提交。
- 存放庫說明本來就是「Free and open source ebook reader for Android」，沒有改。

被這個環境的代理擋下的（HTTP 403）。依環境的規定，這類拒絕不重試、也不改用其他方法繞過：

| 操作 | 回應 |
|---|---|
| 推送標籤 `yokai-fork-point` | `RPC failed; HTTP 403`。我的推送指令內建網路錯誤重試，所以連續試了 4 次，都是 403；確認是代理的拒絕後就沒有再試。同一個環境推送分支是成功的。 |
| 把 `master` 改名為 `main`（GitHub API） | Write access to this GitHub API path is not permitted through this proxy. |
| 開啟 Issues（修改存放庫設定） | Repository settings writes are not permitted through this proxy. |
| 讀寫 Actions 的設定 | Access to this GitHub Actions path is not permitted through this proxy.（這一段工作稍早遇到） |

因應：

- 分叉點標籤改用提交永久連結（1.2）。
- 發布流程不再需要推送標籤（1.3）。
- 改名、Issues、Actions 請你在網頁上操作（第 5 節）。

我也沒有用「推送一個新的 `main` 分支」來代替改名：那樣做無法改預設分支（那是設定，也會被擋），而且之後你在網頁上改名時，會因為 `main` 已經存在而失敗。

## 5. 需要你做的

建議照這個順序。依 GitHub 文件，解除 fork 時「新的存放庫不會保留 issues、PR、wiki、星號、關注者」等資料，所以先解除，再開 Issues、再發布。

1. **解除 fork（Leave fork network）**：存放庫頁面 >「Settings」>「General」（預設就在這頁）> 往下捲到「Danger Zone」> **Leave fork network** > 讀完警告後按 **I have read and understand these effects** > 輸入存放庫名稱 > 按 **Leave fork network**。
   - 這個動作是永久的，之後無法再接回原本的 fork 網路。
   - 條件：公開、小於 1GB、沒有別人從它 fork。【已查證：GitHub API】目前公開、約 102 MB、fork 數 0、星號 0、open issues 0，符合條件。
2. **把 `master` 改名為 `main`**：「Code」分頁 > 分支選單 >「View all branches」> `master` 旁的「…」>「Rename branch」> 輸入 `main` >「Rename branch」。
   - 依 GitHub 文件，改名後舊網址會自動轉到新分支。
   - App 的「這一版的新功能」連的是 `main` 上的 CHANGELOG，發布流程也只在 `main` 上執行，所以這一步是必要的。
3. **開啟 Issues**：「Settings」>「General」>「Features」，勾選「Issues」。
4. **允許 Actions**：「Settings」>「Actions」>「General」，「Actions permissions」選允許執行 Actions 的選項；「Actions」分頁如果出現啟用工作流程的按鈕，請按下去。我無法從這裡查到目前的狀態（第 4 節）。
5. **第一次發布 1.0.0**：「Actions」分頁 > 左側的「Release」>「Run workflow」> 分支選 `main` >「Run workflow」。完成後，Releases 會出現 v1.0.0、五個 APK 與 `SHA256SUMS.txt`。
   - 以後改版時，改 `_versionName`、`versionCode` 與 CHANGELOG，推送到 `main` 就會自動發布，可以請我做。
   - 執行失敗時，請把 Actions 頁面上的錯誤訊息貼給我。
6. **手機上的 App**：先前交付給你的 APK 都是 release 版（最後一版是 1.10.3，套件 `io.github.n09527.bookmania`，用私人金鑰簽章）。如果你手機上裝的是它，Releases 上的 debug 版會是另一個 App（「Bookmania Debug」），兩個並存，資料不共用。
   - 要把書櫃與閱讀進度搬過去：在原本的 App 用「設定 > Data and storage > 建立備份」，再到 Bookmania Debug 用同一頁的「還原備份」。
   - 【推論】書檔本身不在備份裡；Bookmania Debug 要能讀到同一批書，例如在它的「Data and storage」裡把「Storage location」設成同一個資料夾。這一段沒有在實機上試過。
7. **`apk-download` 分支**：只放第 8 階段的 APK。你已經下載完的話可以刪除：「Code」分頁 > 分支選單 >「View all branches」> `apk-download` 旁的垃圾桶圖示。也可以告訴我，我試著刪（刪分支可能也會被這個環境擋下）。

## 6. 刻意保留或沒有處理的上游痕跡

1. **程式內部的名稱**：package（`eu.kanade.tachiyomi`、`yokai.*`）、樣式與資源名稱（例如 `Theme.Widget.Yokai`、`ic_yokai`）、內部 provider 名稱。使用者看不到；改名牽動數百個檔案，業界的 fork 通常也保留【決定】。
2. **Mihon 的說明連結**：見 2.4，共 9 個網址，都是說明沿用功能的第三方文件。
3. **其他語言的翻譯**：英文與正體中文以外，有些語言仍把 App 叫做 Tachiyomi（例如 WebView 的提示），沒有改。另外「Data and storage」「Storage location」等字串本來就沒有正體中文翻譯，畫面上是英文，沒有改。
4. **擴充套件的說明文字**：例如「這個擴充套件不是由 Tachiyomi 所提供」，指的是 Tachiyomi 的擴充套件生態，沒有改。
5. **追蹤服務與線上來源**：登入設定（OAuth 用戶端）沿用 Yōkai，沒有改，也沒有測試（第 6 階段起就列為沒有驗證）。
6. **Renovate 設定**（`.renovaterc.json5`，相依套件更新機器人）：通用設定，保留。
7. **Google Play 服務的程式庫**（`play-services-gcm` 等）：Yōkai 原本就有的相依，不是 Firebase，保留（3.3）。
8. **各階段的報告與測試工具**：第 0～8 階段的報告提到 standard 版、上游 CI 指令與 `ebook-reader/stage1-design` 分支，那是當時的紀錄，沒有改。
9. **工作分支 `ebook-reader/stage1-design`**：內容和 `master` 相同，保留。之後 `main` 改好、確認沒問題，可以刪除，或繼續當工作分支。

## 7. 沒有驗證的項目

- **發布工作流程沒有在 GitHub 上實際執行過**：Actions 的狀態我查不到，也無法從這裡觸發。本機模擬沒有涵蓋：
  - GitHub 執行環境裡的 `sdkmanager` 路徑與 build-tools 35.0.0 的安裝；
  - `gh release view` 與 `gh release create --target` 在 GitHub 上的實際行為；
  - 工作流程的權限能不能建立標籤與 release；
  - 推送到 `main` 時，路徑條件是否如預期觸發。
  - 第一次執行（第 5 節第 5 項）就是實際的驗證。
- **實機**：這次的 APK 都只在模擬器（Android 8.0、WebView 69）上試過，沒有在實體手機上安裝。
- **解除 fork 之後的狀態**：Actions、Issues 等設定在解除後是否保留，要等你操作後才知道。
- **備份搬移到 debug 版**（第 5 節第 6 項）：沒有在實機上試過。
- **debug 版的開發工具**：Chucker 的通知與 LeakCanary 的記憶體傾印在手機上的實際干擾程度，沒有測。
- **3.2 的覆蓋安裝**：1.10.3（162）→ 1.0.0（200）是用前一個 release 建置實測的；最後這個 APK 只測了 1.0.0 → 1.0.0。

## 8. 變更摘要（相對於 Yōkai 的 `843a59b`）

到提交 `a9cd0b2` 為止（不含這份報告），共 810 個檔案：新增 623、修改 63、刪除 124；文字行數 +37,763 / −2,424。

| 範圍 | 新增 | 修改 | 刪除 | 行數 | 二進位檔 |
|---|---|---|---|---|---|
| 各階段的截圖與記錄 `docs/ebook-reader/screenshots` | 411 | 0 | 0 | +11,093 / −0 | 231 |
| App 資源與其他 `app/src`（含圖示） | 6 | 14 | 113 | +196 / −203 | 104 |
| 模擬器檢查工具 `docs/ebook-reader/tools` | 71 | 0 | 0 | +9,777 / −0 | 0 |
| App 程式 `app/src/main/java` | 26 | 33 | 1 | +5,121 / −141 | 0 |
| 各階段報告與設計 `docs/ebook-reader`（其他） | 33 | 0 | 0 | +5,617 / −0 | 0 |
| `core/ebook` 單元測試與測試書 | 28 | 0 | 0 | +555 / −0 | 21 |
| `core/ebook` 解析模組 | 25 | 0 | 0 | +2,927 / −0 | 0 |
| 存放庫文件與工作流程 | 8 | 6 | 10 | +597 / −2,012 | 6 |
| 建置設定與其他（新增的是 `app/debug.keystore` 與開源授權清單的 foliate-js 兩個檔案） | 3 | 7 | 0 | +76 / −58 | 1 |
| App 單元測試 `app/src/test` | 8 | 0 | 0 | +947 / −0 | 0 |
| 字串 `i18n` | 2 | 3 | 0 | +185 / −10 | 0 |
| 閱讀器殼層 `app/src/main/assets` | 2 | 0 | 0 | +672 / −0 | 0 |

這個階段的提交：

| 提交 | 內容 |
|---|---|
| `4429930` | 只剩 Bookmania 建置、移除 Firebase、版本 1.0.0 |
| `e4cd9a1` | App 內的名稱、圖示、連結與「關於」頁 |
| `f29f37a` | README、NOTICE、CHANGELOG、範本與發布工作流程 |
| `1004c14` | 說明連結改到 Bookmania 的 README 與仍然有效的說明頁 |
| `f7bd5bc` | 發布 debug 版，用存放庫裡的 debug 金鑰簽章 |
| `a9cd0b2` | 改成 `main` 上的版本號改變時發布（不需要推送標籤） |
