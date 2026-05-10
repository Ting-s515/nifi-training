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
- 補充文檔只用來釐清容易誤解的概念，不取代 Lab 的實作主線。

## 使用環境

先確認容器已啟動：

```powershell
docker compose start
docker compose ps
```

開啟：

- NiFi UI：`https://localhost:8443/nifi`
- NiFi Registry UI：`http://localhost:18080/nifi-registry`

登入帳密請看本機 `.env`，不要把實際密碼寫進文件或 commit。

注意：課程中的 `docker compose ...` 指令都要在專案根目錄執行，也就是目前包含 `docker-compose.yaml` 的工作目錄。若在其他目錄執行，可能會出現 `no such service: nifi` 或找不到 compose 專案。

## 課程路線

建議照順序完成：

1. [Lab 00：NiFi 基本名詞導讀](00-basic-terms.md)
2. [Lab 01：建立第一個 Flow，理解 Processor、Connection、Queue](01-first-flow.md)
3. [Lab 02：FlowFile、Attribute、Expression Language 與路由](02-flowfile-attributes-routing.md)
4. [Lab 03：CSV Reader/Writer 與 ConvertRecord](03-csv-record-reader-writer.md)
5. [Lab 04：QueryRecord 與 Record 層級資料篩選](04-query-record-filtering.md)
6. [Lab 05：UpdateRecord、RecordPath 與欄位轉換](05-update-record-recordpath.md)
7. [Lab 06：本地 MSSQL 資料庫整合入門](06-database-integration.md)
8. [Lab 07：版本管理、排錯與日常操作](07-versioning-debug-operations.md)
9. [Lab 08：Processor 排程與執行控制](08-scheduling.md)
10. [速查表：常用 Processor 與排錯關鍵字](99-cheatsheet.md)

## 補充閱讀

- [Auto-terminate 完整說明](supplement-auto-terminate.md)
- [NiFi REST API Endpoint 清單](supplement-api-endpoints.md)

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
- Expression Language Guide：https://nifi.apache.org/docs/nifi-docs/html/expression-language-guide.html
- RecordPath Guide：https://nifi.apache.org/nifi-docs/record-path-guide.html
- CSVReader：https://nifi.apache.org/components/org.apache.nifi.csv.CSVReader/
- CSVRecordSetWriter：https://nifi.apache.org/components/org.apache.nifi.csv.CSVRecordSetWriter/
- ConvertRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.ConvertRecord/
- QueryRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.QueryRecord/
- UpdateRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.UpdateRecord/
- DBCPConnectionPool：https://nifi.apache.org/components/org.apache.nifi.dbcp.DBCPConnectionPool/
- PutDatabaseRecord：https://nifi.apache.org/components/org.apache.nifi.processors.standard.PutDatabaseRecord/
- Microsoft JDBC Driver for SQL Server：https://learn.microsoft.com/en-us/sql/connect/jdbc/microsoft-jdbc-driver-for-sql-server
- NiFi Registry：https://nifi.apache.org/registry.html

## 你應該完成到什麼程度

完成後你應該能做到：

- 看懂一條 NiFi flow 的資料怎麼走。
- 看懂 FlowFile、Processor、Connection、Relationship、Queue、Controller Service、Provenance 等基本名詞。
- 判斷 Processor invalid 是缺 property、Controller Service disabled，還是 relationship 沒處理。
- 用 FlowFile Attribute 做基本路由。
- 用 CSVReader/CSVRecordSetWriter 處理 CSV。
- 用 QueryRecord 對 Record 做 SQL-like 篩選。
- 用 UpdateRecord + RecordPath 修改欄位。
- 建立 DBCPConnectionPool，理解 MSSQL JDBC driver、URL、帳密與 validation 的關係。
- 設定 Timer driven、CRON driven、Concurrent Tasks 與基本執行策略。
- 用 queue、bulletin、provenance、logs 找錯。
