# 直書左右雙欄原型（階段 1）

只用於驗證排版做法，不是正式程式碼，也不會打包進 App。

## 內容

| 檔案 | 用途 |
|---|---|
| `gen_book.py` | 產生測試章節 `book/zh.xhtml`（自撰的繁體中文直排內容，含標點、注音、縱中橫、插圖與安全測試項目）、`book/style.css`、`book/fig.svg` |
| `reader/reader.html`、`reader/reader.js` | 閱讀殼層原型：模式 A（`column-wrap`）、B（雙 iframe）、H（橫書多欄）；排版設定注入；逐字驗證函式 `analyze()`、`visibleAt()`、`verifyFast()` |
| `server.mjs` | 本機靜態伺服器；書籍文件加上與正式版相同的 CSP |
| `run.mjs` | 桌面 Chromium（Playwright）的完整逐字驗證、閱讀位置還原、截圖 |
| `fast-run.mjs` | 桌面上以 `verifyFast()` 交叉驗證，含負對照組 |
| `cdp-run.mjs`、`cdp-fast.mjs` | 透過 DevTools 協定在 Android WebView 上執行同一套檢查 |
| `cdp-desktop-check.mjs` | 先在桌面 Chromium 上試跑 `cdp-fast.mjs` |
| `probe-app/` | 只供驗證的 Android 測試 App：虛擬網域 `https://appassets.androidplatform.net/`、CSP、其他網址一律 403、開啟 WebView 偵錯 |
| `android/android-pipeline.sh` | 模擬器流程：等開機、飛航模式、安裝測試 App、轉接偵錯埠、執行 `cdp-fast.mjs` |
| `android/android-followup.sh` | `setBlockNetworkLoads(true)` 檢查、基線 Yokai APK 安裝與啟動 |
| `summarize.py` | 摘要 `run.mjs` 的報告 |

## 重跑方式（桌面）

需要 Node 22、Playwright 與其 Chromium、Python 3。匯入字型測試需要自備一個 CJK 字型檔，放在 `fonts/imported-noto-serif-tc.otf`（原型使用從 Ubuntu `fonts-noto-cjk` 抽出的 Noto Serif CJK TC，SIL OFL 授權，因檔案大小未放入版本庫）。

腳本以絕對路徑 `/opt/node-tools/node_modules/playwright/index.js` 載入 Playwright（本次環境的位置），在其他環境需改成自己的路徑。

```bash
mkdir -p book && python3 gen_book.py book
```

```bash
node run.mjs out
```

```bash
python3 summarize.py out/report.json
```

```bash
node fast-run.mjs
```

## 重跑方式（Android 模擬器）

`probe-app/` 需要放入 assets（`reader/`、`book/`、`fonts/`）後建置；`android/` 下的腳本內含本次環境的絕對路徑，使用前需修改。
