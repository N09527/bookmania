# 階段 7 的檢查：字體加粗與中縫陰影

這些腳本只用於測試，不屬於 App。需要第 3～6 階段資料夾的輔助程式（同一個 `tools/` 之下），以及模擬器上的 debug App。

| 步驟 | 內容 |
|---|---|
| `bold vertical`、`bold horizontal` | 從排版面板的「文字」分頁打開「字體加粗」：書的內文變成粗體（量 `font-weight`），閱讀位置還是同一個字且在畫面上，畫面有變，存成 `pref_ebook_bold`。重開 App 後仍是粗體、同一個字。再關閉：回到書本身的粗細。 |
| `gutter` | 文字閱讀器雙欄的中縫陰影：在截圖上找頁面最暗的一行像素，必須在兩欄之間沒有文字的間隙裡，並且在殼層回報的間隙中央（誤差 3 px），中央最暗、往兩側變淡。從「版面」分頁關閉：沒有陰影，重開後也沒有；再打開：恢復。左邊距 60、右邊距 20：間隙和陰影一起移動。單欄：沒有陰影。「僅橫向畫面」：直向沒有、橫向有。直排書雙欄。捲曲翻頁時錄影，動畫進行中的畫格也有陰影。 |
| `comic` | 漫畫閱讀器（左至右、雙頁）：腳本畫的測試漫畫三頁分別是粉紅、藍、綠。兩頁拼在一起時，粉紅與藍色的交界就是接縫，陰影必須在那裡，而且只在圖片的高度內。捲曲翻頁時錄影，動畫中兩頁相接處有陰影。單獨顯示的第三頁：沒有陰影。「原始尺寸」：接縫不在螢幕中央，陰影仍在接縫上；拖動圖片後，陰影跟著接縫。關閉設定：沒有陰影。 |
| `settings-ui` | 設定 > 閱讀 中，「中縫陰影」在「捲曲翻頁」之後，有說明文字；點一下會存成 `pref_bookmania_pager_gutter_shadow = false`。 |
| `cleanup` | 排版與閱讀器設定恢復預設，直向。 |

```bash
ADB=/path/to/adb python3 -I check_stage7.py bold vertical bold horizontal gutter comic settings-ui cleanup
```

結果在 `out/results.jsonl`（每個檢查一行 JSON），截圖在 `out/shots/`。

捲曲翻頁時的畫面：這部模擬器一次翻頁只畫 3～5 格，截圖（每張 3 秒以上）與一般速度的錄影都抓不到。所以和第 5.5 階段一樣，錄影期間把系統的「動畫時間比例」調成 40 倍（`animator_duration_scale`），用 `screenrecord` 錄下翻頁，再以 ffmpeg 拆成畫格；錄完恢復為 1。只檢查和翻頁前、翻頁後兩個畫面都不同的畫格（動畫進行中）。

## release 版上的兩項功能

`check_release_features.py`：在 `tools/stage6/release_smoke.py` 裝好 release App 並複製 debug App 的書櫃與書之後執行（adb 以 root 執行）。release App 不能用 WebView 的除錯介面，也不能 `run-as`，所以偏好設定與資料庫以 root 讀寫，量測都在截圖上做，方法與 `check_stage7.py` 相同。

| 步驟 | 內容 |
|---|---|
| `text` | 橫排 EPUB、直向、雙欄：陰影在間隙中央。預設邊距 20／20 時，間隙中央是螢幕中央：(412 + 20 − 20) ÷ 2 = 206 CSS px，乘以密度 2.625 = 540.75 px。關閉陰影的開關：沒有陰影。 |
| `bold` | 單欄、同一頁：打開加粗後，頁面上深色像素的比例比關閉時多（至少 1.15 倍）。 |
| `comic` | `check_stage7.py comic` 的測試漫畫（在複製過來的書櫃中），左至右、雙頁、符合螢幕：接縫上有陰影；關閉開關：沒有。 |
| `strings` | 第 8 階段：release App 的作品頁（這部模擬器上是英文介面）：簡介標題是「About this book」，章數仍是「N chapters」。只在指定時執行。 |

```bash
ADB=/path/to/adb python3 -I check_release_features.py            # text bold comic
ADB=/path/to/adb python3 -I check_release_features.py strings    # 第 8 階段的英文字串
```

結果在 `out/release-features/results.jsonl`，截圖在 `out/release-features/shots/`。
