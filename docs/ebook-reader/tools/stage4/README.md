# 階段 4 的模擬器驗證腳本（雙欄）

這些腳本只用於測試，不屬於 App。需求與 `../stage3/README.md` 相同（`adb`、Node.js 22 以上、Python 3、debug APK、測試書；共用 `../stage3/drive.py` 與 `../stage2/cdp.mjs`）。結果寫在環境變數 `OUT` 指定的資料夾，`run-*.sh` 預設為 `out/`（不進版本控制）：`out/results.jsonl` 是各項檢查的通過與否，`out/runs/` 是逐字比對的原始紀錄，`out/shots/` 是截圖。全部重跑：`./run-all.sh checks`，再 `./run-all.sh pages`。

測試書的作品／章節 id（模擬器上的資料庫）：14／16 直排 EPUB、13／15 直排 AZW3、3／1 合併式 MOBI（直排）、8／10 橫排 EPUB、9／11 橫排 MOBI 6。

| 檔案 | 用途 |
|---|---|
| `verify_columns.py <作品id> <章節id> <名稱> [--columns on/off/landscape] [--direction auto/rtl/ltr] [--writing book/vertical/horizontal] [--landscape] [--font-size N]` | 先把排版設定清回預設（全域），設定雙欄等選項，冷啟動開書；之後每按一次 Page Down 記錄一個跨頁，直到全書最後一個跨頁 |
| `probe2.js` | 跨頁中每個 iframe「完全可見」的字（依閱讀順序：第一個 iframe 是跨頁的第一頁）、各 iframe 的位置 |
| `summarize2.py <紀錄檔> [right/left]` | 每個章節檔：所有跨頁可見字串接是否等於全文、是否每個跨頁都看過；第一頁是否在指定的一側 |
| `run-matrix.sh` | 雙欄的全部組合（直書／橫書、兩種翻頁方向、直向強制雙欄、橫向「僅橫向畫面」；EPUB、AZW3、MOBI 6、合併式 MOBI） |
| `run-regression.sh` | 單欄回歸（直書、橫書），以及注音修正啟用時的單欄分頁（字級 30）；雙欄時修正啟用的分頁由 `run-matrix.sh` 涵蓋 |
| `rotate_anchor.py` | 「僅橫向畫面」：直向單欄 → 橫向雙欄 → 直向，頁首的字是否一直在畫面上 |
| `rotate_during_layout.py` | 排版還沒完成就旋轉；選單開著時旋轉，頁碼是否更新 |
| `links2.py` | 雙欄時點兩欄中的連結（外部連結的確認視窗、跨章連結） |
| `panel_columns.py` | 透過真正的設定面板操作「雙欄」：選項、儲存的值、頁碼格式、橫向側邊面板 |
| `ruby.js` | 每個注音的本字與注音各在第幾頁；可先加入一段 CSS（緩解方式的實驗） |
| `ruby_experiments.py` | 各字級下，不同 CSS 的注音錯位數（1.4 節的實驗表） |
| `ruby_check.py`、`run-ruby.sh` | App 本身的注音修正：各字級開書，記錄是否啟用修正、錯位數 |
| `gap.js`、`gap_check.py` | 前幾個區塊（標題、段落、插圖）各在第幾頁，用來查明頁尾留白的原因 |

逐字比對與第 2 階段相同：只比對本文，注音（`rt`、`rp`）不列入；注音另由 `ruby.js` 檢查。

翻頁改用 Page Down 鍵而不是點擊：點擊位置可能剛好落在連結上（會跳出開啟連結的確認視窗）。點擊與連結另外檢查。

這台模擬器沒有硬體加速，System UI 偶爾會「沒有回應」，跳出的系統對話框會搶走按鍵。`verify_columns.py` 在等待與翻頁前會關閉這種對話框（按「等待」），並記在 `out/dialogs.log`；如果是 App 本身沒有回應，也會記在這裡。
