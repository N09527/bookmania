# 變更紀錄

Bookmania 的版本從 1.0.0 開始。分出來之前的變更，見 Yōkai 在分叉點的[變更紀錄](https://github.com/N09527/bookmania/blob/yokai-fork-point/CHANGELOG.md)。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號依 [語意化版本](https://semver.org/lang/zh-TW/)。

## [1.0.0] - 2026-11-24

第一個以 Bookmania 為名的版本，包含 2026-11-16 起的全部開發。各階段的設計、測試與報告見 [docs/ebook-reader](./docs/ebook-reader)。

### 新增

- 文字書閱讀器：EPUB（2、3）、MOBI、AZW3（KF8），從本機來源開啟。
- 直排與橫排排版；翻頁方向依書籍、右開或左開。
- 雙欄（開啟、關閉、僅橫向畫面）與雙欄的中縫陰影；雙欄時左右邊距的上限，避免版面在單欄與雙欄之間跳動。
- 排版設定：字體（可匯入 TTF／OTF）、字級、行距、字距、首行縮排、段落間距、上下左右邊距、字體加粗；全部書籍／這部作品／這個檔案三層；每個數值可以直接輸入。
- 翻頁動畫：捲曲、滑動、無。漫畫閱讀器也可以用捲曲翻頁，雙頁時有中縫陰影。
- 目錄、全書進度滑桿、章節面板；閱讀位置的保存與還原，並寫入備份。
- 受 DRM 保護與損毀的檔案顯示說明，不會當機。
- 書籍內容的隔離：不執行書中的腳本，書的內容不能連網，也不能讀取 App 的其他檔案。

### 變更

- 名稱改為 Bookmania，使用新的圖示與套件名稱 `io.github.n09527.bookmania`。
- GitHub Releases 發布 debug 版（「Bookmania Debug」），以存放庫中固定的 debug 金鑰簽章，新版可以直接覆蓋安裝。
- 版本號從 1.0.0 重新開始（內部編號 200）。先前提供的測試版顯示 1.10.3（內部編號 162），可以直接覆蓋安裝。
- 作品頁的「關於此…」改為「內容簡介」，「共 N 章」改為「共 N 冊」。
- 「關於」頁的 GitHub 連結改為 Bookmania 的存放庫；「這一版的新功能」連到這份變更紀錄。
- 追蹤服務連線時的 User-Agent 改為 Bookmania。
- 「說明」（更多選單、設定頁）改連到 Bookmania 的 README。原本連到 tachiyomi.org 的說明已失效，改為 Mihon 網站上相同主題的說明（來源遷移、新增來源、疑難排解、書櫃常見問題）。

### 移除

- Firebase 當機回報與使用分析，以及「傳送當機報告」設定。
- Yōkai 的建置版本（standard、dev）、發布管道（beta、nightly）與更新來源。「關於」頁每次打開時向 Yōkai 查詢新版本的檢查不再執行（App 沒有內建更新功能）。
- 「關於」頁的 Mihon 網站、Discord 與翻譯平台連結。

[1.0.0]: https://github.com/N09527/bookmania/releases/tag/v1.0.0
