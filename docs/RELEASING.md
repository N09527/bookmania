# 發布新版本

Bookmania 的 APK 用 GitHub Actions 的 [release 工作流程](../.github/workflows/release.yml) 自動建置與發布：推送 `v1.2.3` 這類版本標籤後，它會跑單元測試、用簽章金鑰建置 release APK，並發布到 [Releases](https://github.com/N09527/bookmania/releases)。

## 第一次：設定簽章金鑰（只做一次）

**所有版本都必須用同一把金鑰簽章**，手機上的 App 才能直接覆蓋更新。金鑰遺失後，使用者必須先解除安裝（會清除 App 資料）才能裝新版本。請把金鑰檔與密碼另外備份，例如放在密碼管理器。

金鑰不能放進存放庫，要設定成 GitHub 的 secrets：

1. 準備金鑰檔 `bookmania-release.jks` 與 `SIGNING-INFO.txt`（裡面有密碼與別名）。
2. 把金鑰檔轉成 base64 文字：
   - macOS：`base64 -i bookmania-release.jks | pbcopy`（結果直接複製到剪貼簿）
   - Linux：`base64 -w0 bookmania-release.jks`
   - Windows（PowerShell）：`[Convert]::ToBase64String([IO.File]::ReadAllBytes("bookmania-release.jks")) | Set-Clipboard`
3. 到存放庫的「Settings > Secrets and variables > Actions」，按「New repository secret」，新增這四個：

   | 名稱 | 內容 |
   |---|---|
   | `BOOKMANIA_SIGNING_KEY` | 第 2 步的 base64 文字 |
   | `BOOKMANIA_STORE_PASSWORD` | 金鑰庫密碼 |
   | `BOOKMANIA_KEY_ALIAS` | 金鑰別名（`bookmania`） |
   | `BOOKMANIA_KEY_PASSWORD` | 金鑰密碼 |

4. 確認「Settings > Actions > General」允許執行 Actions。

secrets 存進去之後就讀不出來，所以仍然需要自己保留一份金鑰。

## 每次發布

1. 修改 `app/build.gradle.kts`：
   - `_versionName` 改成新版本，例如 `"1.1.0"`。
   - `versionCode` 加一以上，例如 `201`。**只能變大**，否則手機無法覆蓋安裝。
2. 在 [CHANGELOG.md](../CHANGELOG.md) 新增這一版的段落，標題寫成 `## [1.1.0] - 日期`。release 的說明會取用這一段。
3. 提交並推送到 `main`。
4. 打上標籤並推送（標籤必須和 `_versionName` 相同，前面加 `v`）：

   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```

5. 到存放庫的「Actions」看工作流程的進度，完成後 Releases 會出現新版本，附上五個 APK 與 `SHA256SUMS.txt`。

工作流程會先檢查：標籤和 App 的版本號一致、`BOOKMANIA_SIGNING_KEY` 有設定、每個 APK 的簽章都通過。任何一項不符就停止，不會發布。

## 在自己的電腦上建置簽章版

在 `~/.gradle/gradle.properties` 加上（路徑與密碼換成你的）：

```properties
bookmaniaStoreFile=/path/to/bookmania-release.jks
bookmaniaStorePassword=金鑰庫密碼
bookmaniaKeyAlias=bookmania
bookmaniaKeyPassword=金鑰密碼
```

然後執行：

```bash
./gradlew :app:assembleBookmaniaRelease
```

APK 會出現在 `app/build/outputs/apk/bookmania/release/`。沒有設定這些屬性時，產生的是未簽章的 APK。
