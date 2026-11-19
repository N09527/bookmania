# 階段 3 的模擬器驗證腳本（排版設定）

這些腳本只用於測試，不屬於 App。它們用 uiautomator 操作設定面板，再透過 WebView 除錯介面（只有 debug 版開啟）讀回書籍文件實際套用的 CSS。

需求：與 `../stage2/README.md` 相同（`adb`、Node.js 22 以上、Python 3、已安裝 debug APK 並放好測試書的模擬器），另外：

- App 語言設為繁體中文（腳本以中文標籤尋找按鈕）。本次驗證的做法：App 停止時，以 `run-as` 寫入偏好設定 `app_language=zh-TW` 與 AppCompat 的語系紀錄檔 `files/androidx.appcompat.app.AppCompatDelegate.application_locales_record_file`（內容 `<locales application_locales="zh-TW" />`）。
- 螢幕 1080×1920（座標以此為準）。
- 字型匯入步驟需要把字型放到裝置的 `Download` 資料夾：一個有直排資訊的 OTF（例：從 Noto Serif CJK 的 TTC 取出繁中字型）與一個沒有直排資訊的 TTF（例：DejaVu Sans），檔名寫在 `check_settings.py` 的 `step_fonts`。

| 檔案 | 用途 |
|---|---|
| `drive.py` | adb、uiautomator（節點、點擊、滑桿、捲動面板）與除錯介面的共用函式；`python3 drive.py dump` 列出畫面上的節點 |
| `check_settings.py <步驟…>` | 逐項檢查並輸出 PASS／FAIL，結果附加到 `out/results.jsonl`，截圖在 `out/shots/` |
| `style.js` | 讀回目前頁面的計算後樣式、頁框位置、字型載入狀態與可見文字 |
| `font-guard.js` | 從殼層嘗試載入不合法的字型網址（應全部失敗）與已匯入的字型（應成功） |

步驟（依序執行，後面的步驟依賴前面設定的值）：

```bash
ADB=/path/to/adb python3 check_settings.py reset defaults global direction persist scopes
```

`vol2` 需要同一作品資料夾內的第二個檔案（先在 App 中開一次該作品的詳細頁，讓新章節寫入資料庫），參數是作品 id 與章節 id：

```bash
ADB=/path/to/adb python3 check_settings.py vol2 <作品id> <章節id>
```

```bash
ADB=/path/to/adb python3 check_settings.py reset_levels fonts toolbar rotate
```

決定紀錄 6.1 之後新增的兩個步驟（`FONT_FILE` 指向本機一個大型中文 OTF，腳本直接放進 App 私有目錄，不經過檔案選擇器；`CDP_TIMEOUT_MS` 放寬除錯介面的逾時）：

```bash
ADB=/path/to/adb FONT_FILE=/path/to/NotoSerifCJKtc-Bold.otf CDP_TIMEOUT_MS=120000 python3 check_settings.py font_speed side_panel
```

- `font_speed`：同一本書連續開三個章節檔，記錄每個檔案的排版耗時；再於不使用匯入字型時量一次作為對照。
- `side_panel`：橫向畫面開啟面板，直書時面板在左、橫書時在右；從側邊面板改字體；點面板外的頁面會關閉面板。

注意：模擬器沒有硬體加速時每個步驟都要數分鐘；`uiautomator` 不回報導覽列區域（y ≥ 1794）內的節點，所以腳本會先把面板捲到目標可見再點。
