# 在 iPhone／iPad 安裝 Bookmania（測試版）

Bookmania 的 iOS 版沒有上架 App Store。Releases 上的是**未簽章**的 IPA，要用電腦上的側載工具、以你自己的 Apple ID 簽章後安裝。以下以 Sideloadly 為例。

## 限制【已查證】

- 用免費 Apple ID 簽的 App **7 天後到期**，到期後要用電腦重新簽章安裝一次；每台裝置最多 3 個這類 App（[Apple：會員方案比較](https://developer.apple.com/support/compare-memberships/)）。
- 第一次安裝前，裝置要開啟「開發者模式」（iOS 16 起，[Sideloadly FAQ](https://sideloadly.io/faq)）。
- Windows 版的 Sideloadly 需要網頁版（不是 Microsoft Store 版）的 iTunes 與 iCloud；可能也要安裝 Apple 的 Bonjour（[Sideloadly FAQ](https://sideloadly.io/faq)）。

Sideloadly 不是 Apple 的軟體；它的說明是第三方資料，步驟以它的網站為準。

## 1. 取得 IPA

到存放庫的 [Releases](https://github.com/N09527/bookmania/releases)，在最新版本的「Assets」下載 `bookmania-v版本-ios-unsigned.ipa`（例如 `bookmania-v1.2.0-ios-unsigned.ipa`）。這些都是測試版，還沒有在實機上測試過。同一個版本也附上 Android 的 APK，以及各檔案的 SHA-256（`SHA256SUMS.txt`），可以用來核對下載的檔案（Mac：`shasum -a 256 檔名`；Windows：`certutil -hashfile 檔名 SHA256`）。

兩次發布之間的建置：每次推送改到 iOS 的程式時，「Actions」分頁 > 左側的「iOS」> 該次執行頁面下方的「Artifacts」也有 `Bookmania-ios-unsigned`（zip，解壓後是 `Bookmania-unsigned.ipa`）。要登入 GitHub 才能下載，檔案保存 90 天。一般請用 Releases 上的版本。

## 2. 用 Sideloadly 安裝

1. 在電腦安裝 Sideloadly（[sideloadly.io](https://sideloadly.io/)）。Windows 先裝好網頁版的 iTunes 與 iCloud。
2. 用 USB 線連接 iPhone 或 iPad，在裝置上按「信任這部電腦」。
3. 打開 Sideloadly，把下載的 IPA 拖進視窗，在「Apple ID」欄輸入你的 Apple ID，按「Start」，依提示輸入密碼與雙重認證碼。
4. 完成後，在裝置上：
   - 「設定 > 隱私權與安全性 > 開發者模式」打開（裝置會要求重新開機，開機後確認開啟）。
   - 「設定 > 一般 > VPN 與裝置管理」，點你的 Apple ID，選「信任」。
5. 打開 Bookmania。

**7 天後**：App 無法打開時，重複第 2～3 步，用同一個 Apple ID 重新安裝。【推論】這會覆蓋原本的 App，書與資料保留；第一次重簽時請確認。

## 3. 放書

1. 先打開 Bookmania 一次（它會建立資料夾）。
2. 打開「檔案」App >「我的 iPhone」（或「我的 iPad」）>「Bookmania」>「local」。
3. 每部作品建一個資料夾，把書檔（EPUB、MOBI、AZW3）放進去；漫畫可以放 ZIP／CBZ 檔，或每冊一個圖片資料夾。資料夾名稱就是作品名稱；可以放 `cover.jpg` 當封面。這和 Android 版的本機來源資料夾結構相同。
4. 回到 Bookmania，在「書櫃」下拉或按右上角的重新整理。

不處理受 DRM 保護的書。
