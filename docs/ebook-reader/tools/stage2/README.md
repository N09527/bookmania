# 階段 2 的模擬器驗證腳本

這些腳本只用於測試，不屬於 App。它們透過 `adb` 與 WebView 除錯介面（只有 debug 版開啟）讀取閱讀器狀態。

需求：`adb`、Node.js 22 以上（內建 `WebSocket`）、Python 3；已安裝 `app-bookmania-*-debug.apk` 的模擬器或裝置。

| 檔案 | 用途 |
|---|---|
| `setup-device.sh [install\|prefs\|books]` | 安裝 APK；寫入「導覽已完成」與既有選項「外部 Local Source」；把 `core/ebook/src/test/resources/fixtures/` 的測試書放進 App 專屬資料夾 |
| `verify-book.sh <作品id> <章節id> <點擊x> <名稱>` | 從漫畫閱讀器入口開啟章節（同時驗證交接），一直點「下一頁」到最後，記錄每頁完全可見的字 |
| `summarize.py out/runs/*.jsonl` | 每個章節檔比對「各頁可見字串接」與全文；檢查【第N段】標記順序 |
| `other-cases.sh <作品id> <章節id> <名稱>` | 冷啟動開啟章節，回報前景畫面、錯誤訊息、是否當機 |
| `interact.sh` | 翻頁鍵、方向鍵、音量鍵、外部與跨章連結、旋轉（使用直排 EPUB，作品 id 14、章節 id 16） |
| `cdp.mjs`、`probe.js`、`links.js`、`ui.py` | 除錯介面用戶端、每頁可見文字、連結位置、uiautomator 小工具 |

步驟：

1. `./setup-device.sh`（`ADB=/path/to/adb` 可指定 adb）。
2. 在 App 中開一次每個作品的詳細頁，讓章節寫進資料庫；用 `adb exec-out run-as <套件> cat databases/tachiyomi.db` 取出資料庫查作品與章節 id。
3. 直書點左側（x≈150）、橫書點右側（x≈930，1080 寬的畫面）：`./verify-book.sh 14 16 150 zh-vertical-epub`，再 `python3 summarize.py out/runs/zh-vertical-epub.jsonl`。

`setup-device.sh` 會用到 `out/comic-pages.cbz`（三張 PNG 的 CBZ，任何三張圖片壓成 zip 即可）。

注意：系統第一次進入全螢幕時會出現「Viewing full screen」提示，會擋住自動點擊，請先手動按「GOT IT」。
