# 階段 5 的驗證腳本（閱讀位置、進度、紀錄與操作）

這些腳本只用於測試，不屬於 App。

需求與 `../stage3/README.md` 相同：`adb`、Node.js 22 以上、Python 3、已安裝 debug APK 並放好測試書的模擬器、App 語言為繁體中文、螢幕 1080×1920。`check_stage5.py` 會用到 `../stage3/drive.py` 與 `../stage4/verify_columns.py`。

| 檔案 | 用途 |
|---|---|
| `shell_positions.mjs` | 在桌面版 Chromium（Playwright）直接測殼層的位置函式：以 DOM 位置、文字片段、百分比還原，`goProgress`，以及每一頁第一個字只靠百分比也能還原到同一頁。用法：`node shell_positions.mjs <解開的 EPUB 資料夾> <文件路徑> [直書 0或1] [雙欄 off或on]` |
| `check_stage5.py` | 模擬器上的各項檢查，結果逐行寫入 `out/results.jsonl`，截圖在 `out/shots/`，資料庫副本在 `out/db/`。步驟見檔案開頭的說明 |
| `run-all.sh` | 依序執行本階段在模擬器上的全部自動檢查（約 2 至 3 小時，未加速的模擬器）。`./run-all.sh 7` 從第 7 項開始；`STEPS="3 5 7-40" ./run-all.sh` 只跑指定的項目 |
| `summarize.py` | 依 `out/results.jsonl` 列出每一項的通過數與失敗的檢查 |
| `backup_ui.py` | 在 App 的畫面上建立與還原備份（設定 > Data and storage），搭配 `check_stage5.py` 的 `backup_*` 步驟；順序見檔案開頭的說明 |

`check_stage5.py` 的做法：

- 位置與進度：讀取 App 的 `ebook.db`（`position`、`book` 兩個表）與主資料庫 `tachiyomi.db`（`chapters`、`history`），都在 App 停止後以 `run-as` 複製出來讀。
- 改壞已存位置（測試還原的備援順序）時，App 停止中，複製 `ebook.db` 出來修改後放回。
- 正常離開閱讀器用返回鍵（會觸發 `onPause` 的儲存與閱讀時間），不用強制停止。
- 章節清單的已讀／未讀用滑動切換（既有的章節滑動操作）。每次滑動後停止 App 讀資料庫確認，狀態沒有改變才再滑一次（最多 3 次），所以不會把一次已生效的滑動重複執行；每次滑動後的畫面存為 `swipe-N.png`。
- 點擊區域的預期動作，是照 `app/src/main/java/eu/kanade/tachiyomi/ui/reader/viewer/navigation/` 各類別的區域座標，在腳本中另外算出來再和實際翻頁結果比對。
- 備份：`backup_check` 解開 `.tachibk`（gzip 的 protobuf），不依賴 App 的程式碼，直接讀 `BackupChapter` 的欄位 20101。建立與還原備份在 App 介面上操作（`backup_ui.py`）。既有的備份只包含書櫃中的作品，以及不在書櫃、但有章節已讀或頁數不是 0 的作品；`backup_check` 依同樣的規則決定哪些位置應該在備份中。
- debug 版內建的 LeakCanary 在這部模擬器上會反覆分析堆積檔、拖慢 App（見階段 5 報告 3.11）。驗證前在模擬器上把它的堆積檔資料夾換成唯讀檔案：`adb shell "run-as <套件> sh -c 'rm -rf cache/leakcanary; echo blocked > cache/leakcanary; chmod 444 cache/leakcanary'"`（只影響這部模擬器上的 App 資料）。
- 模擬器剛開機時第一次開書要好幾分鐘，先執行 `warmup`。每一項結束後，系統紀錄中的當機與「沒有回應」事件附加到 `out/system-events.log`。
