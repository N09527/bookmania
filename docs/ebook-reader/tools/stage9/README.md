# 階段 9 的檢查：Bookmania 1.0.0

這些腳本只用於測試，不屬於 App。需要第 3、5 階段資料夾的輔助程式（同一個 `tools/` 之下）與模擬器；結果見 `docs/ebook-reader/stage9-report.md` 第 3 節，紀錄在 `docs/ebook-reader/screenshots/stage9/`。

| 腳本 | 內容 |
|---|---|
| `verify_rebrand.py <release APK>` | release 版：把新的 APK 直接覆蓋安裝在現有的 release 版上（檢查版本變成 1.0.0、內部編號 200）、書櫃還在、「關於」頁顯示 Release 1.0.0、連結只剩 GitHub、沒有翻譯連結，以及系統記錄裡沒有 Firebase 與 `api.github.com`。結果在 `$OUT/results.jsonl`，截圖在 `$OUT/`。 |
| `debug_smoke.py` | debug 版：四本測試書（直排 EPUB、橫排 EPUB、直排 AZW3、橫排 MOBI 6）各自從圖片閱讀器的入口開啟，確認進入文字閱讀器、排版完成，按一次翻頁鍵後頁碼前進。每本書印出一行 JSON，截圖在 `$OUT/shots/`。 |

```bash
ADB=/path/to/adb OUT=out/release python3 -I verify_rebrand.py app-bookmania-universal-release.apk
ADB=/path/to/adb python3 -I debug_smoke.py
```

注意：

- `verify_rebrand.py` 的 Firebase 檢查讀的是整個系統記錄，模擬器上其他 App 的訊息也會算進去。第 9 階段那次失敗，就是因為當時的舊 debug 版還帶著 Firebase；報告 3.2 說明了怎麼確認 release 版本身沒有。
- 這兩個腳本都假設模擬器上已經有第 2～8 階段的測試書與書櫃（作品與章節的編號寫在腳本裡），App 語言是正體中文。
- debug 版換成存放庫的 debug 金鑰後，必須先解除安裝舊的 debug 版。第 9 階段的做法：從 release 版的資料複製書櫃資料庫、閱讀位置資料庫、偏好設定與書檔，並寫入 AppCompat 的語系紀錄檔（見 `../stage3/README.md`）。複製或備份 App 資料後，關閉模擬器前要先執行 `adb shell sync`，否則檔案可能沒有寫完（第 9 階段的備份因此不完整，見報告 3.5）。
