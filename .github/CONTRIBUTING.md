# 參與 Bookmania

謝謝你願意幫忙。（English summary at the end.）

## 回報問題與建議

請到 [Issues](https://github.com/N09527/bookmania/issues) 使用範本。回報問題時請附上：

- App 版本（設定 > 關於 > 版本，點一下會複製裝置資訊）。
- 手機型號、Android 版本，以及「Android System WebView」的版本（文字閱讀器用它排版）。
- 重現的步驟。如果和某本書有關，請說明書的格式（EPUB、MOBI、AZW3）與排版（直排或橫排）。**不要上傳有版權的書**；可以的話，用自己做的小檔案重現。

受 DRM 保護的書不在支援範圍內。Bookmania 不會加入移除 DRM 的功能，相關的請求會直接關閉。

## 貢獻程式碼

### 建置與測試

需要 JDK 21 與 Android SDK。

```bash
./gradlew :app:assembleBookmaniaDebug
./gradlew :app:testBookmaniaDebugUnitTest :core:ebook:testDebugUnitTest :domain:testDebugUnitTest
```

模擬器上的自動檢查腳本與說明在 `docs/ebook-reader/tools/`。

### 程式碼的位置

- 文字書的解析：`core/ebook`（EPUB、MOBI、AZW3 的讀取與 DRM、損毀檢查）。
- 文字閱讀器：`app/src/main/java/yokai/ebook` 與 `app/src/main/assets/ebook`（WebView 裡的排版程式）。
- 翻頁動畫：`yokai.pageturn`；中縫陰影：`yokai.gutter`。
- 其他大多沿用 Yōkai 的程式。程式的 package 名稱（`eu.kanade.tachiyomi`、`yokai`）沿用上游，沒有改名。

### 原則

- 書籍內容視為不可信：不執行書裡的腳本，不讓書的內容連網或讀取 App 的其他檔案。
- 不加入任何移除或繞過 DRM 的功能。
- 新增的第三方元件要確認授權能與 Apache-2.0 併用（特別留意 GPL、LGPL、AGPL），並列入 App 的開源授權清單。
- 資料庫只新增 migration，不修改既有的；備份 protobuf 不更動、不重複使用欄位編號；不改變既有偏好設定鍵的意義。
- 介面文字至少提供英文與正體中文。
- 一個 PR 只做一件事，並說明怎麼測試過。

## English summary

Please report problems and suggestions in the [Issues](https://github.com/N09527/bookmania/issues) with the App version, phone model, Android and Android System WebView versions, and steps to reproduce (do not upload copyrighted books). Removing DRM is out of scope and will not be added.

To build: JDK 21, Android SDK, `./gradlew :app:assembleBookmaniaDebug`. Book content is untrusted (no scripts, no network, no access to the App's files); new third-party components must have licenses compatible with Apache-2.0; database migrations and backup fields are only ever added; UI text needs at least English and Traditional Chinese.
