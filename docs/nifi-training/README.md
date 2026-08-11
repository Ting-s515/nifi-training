# NiFi 實作入門課程

這組課程用目前專案的 Docker Compose NiFi 環境練習，目標是讓你能在公司專案中看懂、建立、排錯與維護基本資料流。

本課程不先大量講理論。每一章都會要求你在 NiFi UI 建一個小流程，跑資料，觀察 queue、attributes、content、bulletin、provenance，再把結果和實務概念對起來。

每個 Lab 最下方都有「本 Lab 的學習重點回顧」，用來說明整條流程在做什麼、每個 Processor 負責什麼，以及這個練習對公司專案的意義。

## 課程設計主旨

本課程採用「做中學」設計。每個主題都應該先讓你完成一個可執行、可觀察的小流程，再用該流程反推 NiFi 名詞、設定與排錯觀念。

課程編排原則：

- 先實作，再解釋。不要先堆大量理論，最後才操作。
- 每個 Lab 都要有明確輸入、處理步驟、輸出或觀察點。
- 每次只引入少量新概念，並且要能在 UI、queue、log 或 provenance 中看得到。
- 理論說明要服務於當前實作，不寫和當前 Lab 無關的大段背景知識。
- 每個 Lab 結尾要回顧整條 flow 在做什麼，避免只照步驟完成卻不知道流程意義。
- 每個 Step 都要用「新手是否能從上一個 Step 的狀態直接照做」來檢查；若前一步留下的設定會影響下一步，必須明確寫出要保留、修改或刪除哪些設定。
- NiFi UI 若提供多個獨立 property，就依照 property 語意分開填，不要把外部工具或 SQL 慣用的完整字串硬塞進單一欄位。例如 MSSQL 在 `PutDatabaseRecord` 要分開填 `Database Name`、`Schema Name`、`Table Name`，不要把 `dbo.table_name` 全部填到 `Table Name`。
- 需要擴充 NiFi SPI 時，優先使用 `nifi-api`、`nifi-mock`、ServiceLoader 與 NAR 公開契約；REST 操作以目前版本 Swagger 驗證，避免依賴 UI 內部實作。
- 補充文檔只用來釐清容易誤解的概念，不取代 Lab 的實作主線。

課程檔名規則：

- 一般主線 Lab 使用 `NN-topic.md`，例如 `01-first-flow.md`。
- 若某個 Lab 需要延伸成系列課程，改用 `NN-00-topic.md` 作為主課，後續用 `NN-01-topic.md`、`NN-02-topic.md` 擴充。
- 文件標題仍使用人類可讀的課程編號，例如 `# Lab 06：...`、`# Lab 06-1：...`、`# Lab 06-2：...`。
- 範例：
  - `06-00-database-integration.md` 對應 `Lab 06`
  - `06-01-database-read-copy.md` 對應 `Lab 06-1`
  - 未來可新增 `06-02-xxx.md` 對應 `Lab 06-2`

## 使用環境

課程啟動分成兩層：先啟動 NiFi runtime，再依 Lab 建置與部署課程範例。容器顯示
`Up` 只代表 NiFi 服務正在執行，不代表 Lab 11 的 custom Processor 已經安裝。

### 首次啟動 NiFi runtime

第一次啟動時，先建立本機 `.env`，再建置 Compose 使用的 `nifi-sample` 映像：

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.sample .env }
notepad .env
docker build -t nifi-sample .
docker compose up -d
docker compose ps
```

請在 `.env` 填入本機使用的 `NIFI_USERNAME` 與 `NIFI_PASSWORD`。`.env` 只保留在本機，
不要提交實際帳密。

後續若容器已建立，只要重新啟動環境，可執行：

```powershell
docker compose up -d
docker compose ps
```

開啟：

- NiFi UI：`https://localhost:8443/nifi`
- NiFi Registry UI：`http://localhost:18080/nifi-registry`

登入帳密請看本機 `.env`，不要把實際密碼寫進文件或 commit。

### Lab 11 的額外初始化

Lab 11 的 `ContentDigestProcessor` 不在 `nifi-sample` 基礎映像內。NiFi runtime 啟動後，
還要先將課程範例建置成 NAR，再上傳並安裝到 NiFi，Processor type 才會出現在 runtime
中。請從 repository 根目錄執行：

```powershell
.\examples\nifi-custom-processor\build.ps1
.\examples\nifi-custom-processor\scripts\setup-flow.ps1
```

第二個腳本會讀取 `.env`、上傳 NAR、等待安裝完成、確認 Processor type，並建立測試
Process Group。完整的 API 與驗證說明請接著閱讀
[Lab 11：使用 NiFi SPI 開發自訂 Processor](11-00-custom-processor-spi.md)。

注意：課程中的 `docker compose ...` 指令都要在專案根目錄執行，也就是目前包含 `docker-compose.yaml` 的工作目錄。若在其他目錄執行，可能會出現 `no such service: nifi` 或找不到 compose 專案。

## 產生與啟動雙欄式 HTML 閱讀器

`docs/nifi-training` 是由 Markdown 在 build 時產生的純靜態文件網站。左欄提供分類目錄、搜尋與前後頁切換，右欄顯示課程內容；程式碼區塊支援複製，Mermaid 圖表支援放大、縮放與拖曳。

網站建置需要 Node.js 24 以上。以下指令都要在 repository 根目錄執行；PowerShell 使用 `npm.cmd` 可避免 npm script execution policy 造成的啟動問題。

### 首次設定

安裝閱讀器的 build、Markdown render、Mermaid 與測試相依套件：

```powershell
npm.cmd --prefix ./docs/nifi-training install
```

### 測試與建置

```powershell
# 執行文件清單、連結、複製與 Mermaid dialog 契約測試
npm.cmd --prefix ./docs/nifi-training test

# 從目前 Markdown 來源重新產生靜態網站
npm.cmd --prefix ./docs/nifi-training run build
```

### 啟動本機文件網站

`dev` 會先執行 build，再啟動只綁定 `127.0.0.1:18100` 的靜態伺服器：

```powershell
npm.cmd --prefix ./docs/nifi-training run dev
```

開啟 <http://127.0.0.1:18100>，完成後按 `Ctrl+C` 停止伺服器。

如果已經完成 build，只想啟動靜態伺服器，可使用：

```powershell
npm.cmd --prefix ./docs/nifi-training run preview
```

### 輸出與來源

- Markdown 來源：`docs/nifi-training/*.md`
- 閱讀器來源：`docs/nifi-training/src/`
- 建置腳本與靜態伺服器：`docs/nifi-training/script/`
- 產生檔案：`docs/nifi-training/index.html`、`style.css`、`app.mjs`

既有的直接產生入口仍保留為相容 wrapper，但必須先完成相依套件安裝：

```powershell
node docs/nifi-training/mdx/build-training-html.mjs
```

## 課程路線

建議照順序完成：

1. [Lab 00：NiFi 基本名詞導讀](00-basic-terms.md)
2. [Lab 01：建立第一個 Flow，理解 Processor、Connection、Queue](01-first-flow.md)
3. [Lab 02：FlowFile、Attribute、Expression Language 與路由](02-flowfile-attributes-routing.md)
4. [Lab 03：CSV Reader/Writer 與 ConvertRecord](03-csv-record-reader-writer.md)
5. [Lab 04：QueryRecord 與 Record 層級資料篩選](04-query-record-filtering.md)
6. [Lab 05：UpdateRecord、RecordPath 與欄位轉換](05-update-record-recordpath.md)
7. [Lab 06：本地 MSSQL 資料庫整合入門](06-00-database-integration.md)
8. [Lab 06-1：從 MSSQL 讀取資料表資訊並複製資料](06-01-database-read-copy.md)
9. [Lab 07：版本管理、排錯與日常操作](07-versioning-debug-operations.md)
10. [Lab 08：Processor 排程與執行控制](08-scheduling.md)
11. [Lab 09：NiFi Cluster 入門與多節點執行觀念](09-clustering.md)
12. [Lab 10：Query、Formatter 與 Expression Language 實戰](10-query-format-expression-language.md)
13. [Lab 11：使用 NiFi SPI 開發自訂 Processor](11-00-custom-processor-spi.md)
14. [速查表：常用 Processor 與排錯關鍵字](99-cheatsheet.md)

## 補充閱讀

- [Auto-terminate 完整說明](supplement-auto-terminate.md)
- [JDBC Driver Jar 完整說明](supplement-jdbc-driver.md)
- [NiFi REST API Endpoint 清單](supplement-api-endpoints.md)

Lab 11 的可建置 Java 範例位於：

```text
examples/nifi-custom-processor/
```

其中包含 Processor 原始碼、`nifi-mock` 測試、NAR 打包與 REST API flow 建立腳本。

## 每個 Lab 的操作原則

- 每個 Lab 建議建立獨立 Process Group，例如 `training-lab-01`。
- Processor 先保持 stopped，全部 validation 通過後再 start。
- 練習時不要讓 `GenerateFlowFile` 跑太快，建議設定 `Run Schedule = 60 sec`，確認流程後再手動 stop。
- 每個 Lab 結束後，先清空 queue 或保留成排錯練習，不要讓測試資料一直累積。
- 改 Controller Service 後，若 Processor 顯示 invalid，先確認 service 是否已 `Enabled`。
- 練習題若會沿用同一個 Processor，必須先確認上一題留下的 dynamic property、relationship、auto-terminate 或排程設定是否需要清除。

## 官方文件依據

本課程內容已對照 Apache NiFi 2.x 官方文件與元件文件：

- NiFi User Guide：https://nifi.apache.org/nifi-docs/user-guide.html
- NiFi Administration Guide：https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html
- Expression Language Guide：https://nifi.apache.org/docs/nifi-docs/html/expression-language-guide.html
- RecordPath Guide：https://nifi.apache.org/nifi-docs/record-path-guide.html
- CSVReader：https://nifi.apache.org/components/org.apache.nifi.csv.CSVReader/
- CSVRecordSetWriter：https://nifi.apache.org/components/org.apache.nifi.csv.CSVRecordSetWriter/
- ConvertRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.ConvertRecord/
- QueryRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.QueryRecord/
- UpdateRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.UpdateRecord/
- DBCPConnectionPool：https://nifi.apache.org/components/org.apache.nifi.dbcp.DBCPConnectionPool/
- ExecuteSQLRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.ExecuteSQLRecord/
- PutDatabaseRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.PutDatabaseRecord/
- Microsoft JDBC Driver for SQL Server：https://learn.microsoft.com/en-us/sql/connect/jdbc/microsoft-jdbc-driver-for-sql-server
- SQL Server INFORMATION_SCHEMA.COLUMNS：https://learn.microsoft.com/en-us/sql/relational-databases/system-information-schema-views/columns-transact-sql
- NiFi Registry：https://nifi.apache.org/registry.html
- GitHubFlowRegistryClient：https://nifi.apache.org/components/org.apache.nifi.github.GitHubFlowRegistryClient/
- GitLabFlowRegistryClient：https://nifi.apache.org/components/org.apache.nifi.gitlab.GitLabFlowRegistryClient/
- GitHub Personal Access Tokens：https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens

## 你應該完成到什麼程度

完成後你應該能做到：

- 看懂一條 NiFi flow 的資料怎麼走。
- 看懂 FlowFile、Processor、Connection、Relationship、Queue、Controller Service、Provenance 等基本名詞。
- 判斷 Processor invalid 是缺 property、Controller Service disabled，還是 relationship 沒處理。
- 用 FlowFile Attribute 做基本路由。
- 用 CSVReader/CSVRecordSetWriter 處理 CSV。
- 用 QueryRecord 對 Record 做 SQL-like 篩選。
- 用 UpdateRecord + RecordPath 修改欄位。
- 用 Expression Language 對 record 欄位做字串替換、遮罩與日期格式化。
- 建立 DBCPConnectionPool，理解 MSSQL JDBC driver、URL、帳密與 validation 的關係。
- 用 ExecuteSQLRecord 從 MSSQL 查 table metadata 與資料列。
- 用 ExecuteSQLRecord + PutDatabaseRecord 做本地 DB 到本地 DB 的資料複製。
- 設定 Timer driven、CRON driven、Concurrent Tasks 與基本執行策略。
- 看懂 cluster 中 `All Nodes`、`Primary Node`、connection load balancing 與 cluster state 的基本影響。
- 使用 NiFi 公開 Java API 實作、測試並打包一個 custom Processor NAR。
- 透過 REST API 上傳 NAR、建立 Processor 與 connection、執行 `RUN_ONCE` 並讀回 FlowFile attribute。
- 用 queue、bulletin、provenance、logs 找錯。
