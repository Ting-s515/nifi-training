# Repository Guidelines

## 專案結構

本 repository 提供 Apache NiFi 2.9.0 的本機 Docker 環境與實作課程。

- `docs/nifi-training/`：Lab、速查表、補充說明與純靜態文件網站；`README.md` 是課程入口。
- `docs/nifi-training/src/`：閱讀器 HTML、CSS、ES module 與可獨立測試的 helper 來源。
- `docs/nifi-training/script/`：Markdown build pipeline 與本機靜態伺服器。
- `docs/nifi-training/test/`：文件清單、連結、複製與 Mermaid dialog 契約測試。
- `docs/nifi-training/mdx/build-training-html.mjs`：保留既有直接執行路徑的相容 wrapper。
- `docs/nifi-description.md`：NiFi 概念與環境說明。
- 根目錄的 `Dockerfile`、`docker-compose.yaml`、`requirements.txt`、JDBC JAR
  與 `.env.sample`：建置及執行環境設定；`zip/` 保存驅動程式壓縮檔。

## 建置、測試與本機開發

所有指令都從 repository 根目錄執行。首次啟動可使用：

```powershell
Copy-Item .env.sample .env
# 編輯 .env 後填入本機帳密
docker build -t nifi-sample .
docker compose up -d
docker compose ps
```

使用 `docker compose logs -f nifi` 追蹤 NiFi；完成後用 `docker compose down` 停止服務。
`docker compose down -v` 會刪除練習用 volumes，僅在確認資料可重建時使用。

修改課程 Markdown 或閱讀器來源後，執行：

```powershell
npm --prefix ./docs/nifi-training install
npm --prefix ./docs/nifi-training test
npm --prefix ./docs/nifi-training run build
```

網站測試使用 Node.js 內建 `node:test`，目前沒有 coverage 門檻；仍應在瀏覽器檢查
`docs/nifi-training/index.html` 的目錄、文件切換、heading deep link、程式碼複製、
Mermaid 圖表與課程內容。

## Code Review

本專案不需要 Code Review，任何變更都不啟動 reviewer 流程；仍須依變更類型完成適用的
build、test 或文件驗證。

## 撰寫規範

課程文件使用繁體中文與 Markdown，Lab 檔名遵循 `NN-topic.md`；系列課程使用
`NN-00-topic.md`、`NN-01-topic.md`。修改課程內容時同步更新
`docs/nifi-training/README.md`。閱讀器產出檔不要手動編輯，應修改來源後重新產生。
JavaScript/HTML 延續現有 2 空格縮排、雙引號與分號風格；註解只說明原因。Mermaid
換行使用 `<br>`，不要使用 `\n`。

## Commit 與 Pull Request

沿用 Git 歷史中的 Conventional Commits，例如 `docs: 更新 Lab 06`、
`feat(docs): 新增課程閱讀器` 或 `fix(compose): 修正時區`。PR 應說明影響的 Lab
或環境檔、列出已執行的驗證指令；若修改閱讀器介面，附上截圖。絕不提交 `.env`
中的實際密碼、token 或其他憑證。
