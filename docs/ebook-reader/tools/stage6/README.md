# 階段 6 的回歸測試

這些腳本只用於測試，不屬於 App。`run-regression.sh` 依序執行第 2～5.5 階段的自動檢查。每一部分的需求與說明見各階段資料夾的 README。

| 部分 | 內容 | 結果 |
|---|---|---|
| `warmup` | 模擬器開機後先開一次書（第一次開書要好幾分鐘） | `out/warmup/` |
| `s55new` | 使用者在第 5.5 階段報告 6.1 的決定：文字閱讀器預設捲曲（`t-default`）；漫畫閱讀器開啟捲曲時，手指滑動也以捲曲翻頁（左至右、往前翻、右至左、直向、捲曲關閉、長條模式）；設定的新預設 | `../stage5_5/out6/` |
| `s55` | 第 5.5 階段其餘的翻頁動畫、章節面板與快速翻頁檢查 | `../stage5_5/out6/` |
| `s5` | 第 5 階段：閱讀位置、進度、目錄與滑桿、點擊區、音量鍵、文字／圖片切換、判定（約 2～3 小時） | `../stage5/out6/` |
| `s4checks` | 第 4 階段：排版中旋轉、面板的雙欄設定、連結、整頁插圖、注音 | `../stage4/out6/` |
| `s4pages` | 第 4 階段：逐頁翻完並逐字比對（雙欄矩陣、單欄） | `../stage4/out6/` |
| `s3` | 第 3 階段：排版設定、三層覆寫、保存、字型匯入、工具列、旋轉、字型載入時間、側邊面板 | `../stage3/out6/` |
| `s2` | 第 2 階段：DRM、損毀檔、漫畫 EPUB 與 CBZ、EPUB 2 目錄、圖文書的開啟結果 | `../stage2/out6/` |

另外有一項新的檢查（第 6 階段新增，不屬於前幾個階段）：

| 檔案 | 內容 | 結果 |
|---|---|---|
| `check_security.py` | 書籍內容的安全：測試書（`make_hostile_epub.py`）嘗試執行腳本、連到另一台主機、讀取本機檔案。用 WebView 的除錯介面檢查打開的書，並記錄有沒有請求到達這台機器上的測試伺服器（模擬器以 10.0.2.2 連到它）。單欄與雙欄各一輪。測試期間關閉飛航模式，結束後恢復 | `out/security/` |

驗收補測（任務文件第 8 節）：逐條對照第 8 節後，補做前幾個階段沒有涵蓋的部分。結果都只代表這部 Android 8.0 模擬器（WebView 69，沒有硬體加速）。

| 檔案 | 內容 | 結果 |
|---|---|---|
| `check_acceptance.py`（`run-acceptance.sh` 依序執行） | `fonts`：從排版面板與系統檔案選擇器匯入字型，套用到橫書與直書的內文，重開後仍使用（第 5 項）。`glyphs`：直排的中文與日文頁面，以書籍字型與匯入字型各截圖，供目視（第 6 項）。`positions vertical`／`positions horizontal`：從第一個檔案的中段開始，依序改變 2.3 的每一項設定；每次都確認閱讀位置仍是同一個字且在畫面上、設定已套用、畫面有變。之後重開 App 檢查設定都保留，再旋轉螢幕（第 4、8 項）。`corrupt`：損毀的 MOBI、AZW3 顯示 App 的說明；損毀的 EPUB 交給圖片閱讀器，從無障礙事件讀取它的提示文字（第 3 項）。`cleanup`：移除匯入的字型與排版設定 | `out/acceptance/` |
| `check_legacy.py` | 既有功能的離線回歸（第 2 項）。`library`：從作品頁加入書櫃，書櫃列出並可開啟。`local`：Local Source 的圖片資料夾與 zip 章節。`modes`：漫畫閱讀器五種閱讀模式。`screens`：主要分頁、探索中的本機來源、下載佇列、各設定類別。`backup`：在 App 中建立備份，把一部作品移出書櫃，再從備份還原。`cleanup`：移除 `local` 新增的章節。依使用者的決定，擴充套件、線上下載與追蹤服務不在這裡測 | `out/legacy/` |
| `make_long_books.py` | 長篇測試書（文字由腳本產生）：直排與橫排 EPUB 各約 101 萬字、100 個檔案；由 Calibre 轉出的 AZW3；10 萬字的單一檔案 EPUB | `out/long-books/` |
| `measure_long.py`、`open_poll.mjs` | 長篇書的開書時間（冷啟動到第一頁排好，從這台電腦每 0.1 秒查詢一次閱讀器）、記憶體，以及檔案內與跨檔案的翻頁時間（第 9 項） | `out/long/` |

```bash
ADB=/path/to/adb ./run-acceptance.sh                       # warmup、fonts、glyphs、positions、corrupt、cleanup
ADB=/path/to/adb python3 -I check_legacy.py library local modes screens backup cleanup
python3 -I make_long_books.py out/long-books
ADB=/path/to/adb python3 -I measure_long.py setup          # 之後：open <標籤>、middle <標籤>、turns <標籤>、cleanup
```

用法：

```bash
ADB=/path/to/adb FONT_FILE=/path/to/NotoSerifCJKtc-Bold.otf ./run-regression.sh            # 全部
ADB=/path/to/adb ./run-regression.sh s5 s4pages                                         # 只跑指定的部分
```

`out/parts.log` 記錄每一部分的開始、結束時間與結束代碼；`out/<部分>-events.log` 是該部分期間系統紀錄中的當機與「沒有回應」事件。

注意：
- 第 2～5 階段的部分開始前，腳本把漫畫閱讀器的「捲曲翻頁」開關恢復為預設值（關閉）。第 5.5 階段的檢查會開關這個全域設定，舊階段的腳本不會重設它。
- 從第 6 階段起，文字閱讀器的預設翻頁動畫是捲曲，所以前幾個階段的檢查也會經過翻頁動畫（第 3～5 階段的腳本會清除排版設定，翻頁動畫因此回到預設值）。
- 作品「橫排測試書 EPUB」在第 5.5 階段多了兩個檔案（`zh-varied.epub` 與 `zh-horizontal-vol3-pictures.cbz`）。
- 安全檢查會把測試書 `zh-security-test.epub` 加入作品「橫排測試書 EPUB」，之後留在那裡。
