# 發布新版本

Bookmania 在 [Releases](https://github.com/N09527/bookmania/releases) 發布的是 **debug 版**（自用）。`main` 上 `app/build.gradle.kts` 的版本號改變並推送後，GitHub Actions 的 [release 工作流程](../.github/workflows/release.yml) 會自動跑單元測試、建置 debug 版的五個 APK、檢查簽章，然後建立版本標籤 `v1.2.3`，發布 APK 與 SHA-256。不需要設定任何 secrets，也不需要自己推送標籤。已經發布過的版本會跳過。

## debug 版是什麼

- App 名稱「Bookmania Debug」，套件名稱 `io.github.n09527.bookmania.debug`。和 release 版（`io.github.n09527.bookmania`）是不同的 App：可以同時安裝，資料不共用。
- 沒有經過 R8 縮減，檔案較大、速度較慢。
- 含開發用工具：網路檢查 Chucker 在 App 連網時會顯示通知；記憶體洩漏偵測 LeakCanary 發現洩漏時會傾印記憶體並顯示通知，傾印時 App 可能停頓幾秒。
- 用存放庫裡的 debug 金鑰 `app/debug.keystore` 簽章（別名 `androiddebugkey`，密碼 `android`）。每次建置都用同一把，所以新版可以直接覆蓋安裝舊版，資料保留。
- 這把金鑰是公開的：任何人都能用它簽出可以覆蓋你這個 debug 版的 APK。只從這個存放庫的 Releases 下載，就不會遇到這種情況。
- **不要更換或刪除 `app/debug.keystore`**。換了之後，新版就無法覆蓋安裝舊版，必須先解除安裝（會清除 App 資料）。

## 每次發布

1. 修改 `app/build.gradle.kts`：
   - `_versionName` 改成新版本，例如 `"1.1.0"`。
   - `versionCode` 加一以上，例如 `201`。**只能變大**，否則手機無法覆蓋安裝；沒有比上一個發布的版本大時，工作流程會停止。
2. 在 [CHANGELOG.md](../CHANGELOG.md) 新增這一版的段落，標題寫成 `## [1.1.0] - 日期`，並在檔尾加上 `[1.1.0]: https://github.com/N09527/bookmania/releases/tag/v1.1.0`。發布的說明會取用這一段。
3. 提交並推送到 `main`。推送的變更包含 `app/build.gradle.kts` 時，工作流程會自動開始。
4. 到存放庫的「Actions」看進度。完成後 Releases 會出現新版本，附上五個 APK 與 `SHA256SUMS.txt`。

也可以手動執行：「Actions」分頁 > 左側的「Release」>「Run workflow」，分支選 `main`。它會發布 `main` 目前的版本；這個版本已經發布過時，什麼都不做。適合用在第一次發布、或上一次執行失敗之後重試。

工作流程會先檢查：只在 `main` 上執行；這個版本還沒發布；同名的標籤如果已經存在，必須指向同一個提交；`versionCode` 比上一個發布的版本大；每個 APK 都用 `app/debug.keystore` 簽章。任何一項不符就停止，不會發布。

第一次使用前，請確認「Settings > Actions > General」的「Actions permissions」允許執行 Actions；「Actions」分頁如果出現啟用工作流程的按鈕，請按下去。

## release 版（選用）

release 版（經過 R8 縮減、沒有開發工具）用另一把私人的金鑰簽章，金鑰不在存放庫中。在自己的電腦上建置時，在 `~/.gradle/gradle.properties` 加上（路徑與密碼換成你的）：

```properties
bookmaniaStoreFile=/path/to/bookmania-release.jks
bookmaniaStorePassword=金鑰庫密碼
bookmaniaKeyAlias=bookmania
bookmaniaKeyPassword=金鑰密碼
```

然後執行 `./gradlew :app:assembleBookmaniaRelease`，APK 在 `app/build/outputs/apk/bookmania/release/`。沒有設定這些屬性時，產生的是未簽章的 APK。release 版的金鑰遺失後，同一個 release 版就無法再更新，請另外備份。
