# Repository Guidelines

## 專案結構

本 repository 提供 Apache NiFi 2.9.0 的本機 Docker 環境與實作課程。

- `docs/nifi-training/`：Lab、速查表與補充說明；`README.md` 是課程入口。
- `docs/nifi-training/mdx/`：Markdown 閱讀器範本與產生器；輸出為同目錄的 `index.html`。
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

修改課程 Markdown 或閱讀器範本後，執行：

```powershell
node docs/nifi-training/mdx/build-training-html.mjs
```

目前沒有正式測試框架或 coverage 門檻；至少應執行上述產生器，並在瀏覽器檢查
`docs/nifi-training/index.html` 的目錄、搜尋、前後頁與課程內容。

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
