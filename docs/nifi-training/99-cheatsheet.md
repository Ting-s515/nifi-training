# NiFi 入門速查表

## 基本名詞速查

| 名詞 | 白話說明 | 常見位置 |
| --- | --- | --- |
| `FlowFile` | NiFi 裡的一筆資料包裹，包含 content 與 attributes | Queue、Provenance、LogAttribute |
| `Content` | FlowFile 的真正資料內容 | CSV、JSON、XML、檔案內容 |
| `Attributes` | FlowFile metadata | `filename`、`uuid`、`record.count` |
| `Processor` | 處理資料的節點 | Canvas 上的方塊 |
| `Connection` | Processor 之間的線，也包含 queue | Canvas 連線 |
| `Relationship` | Processor 處理後的出口 | `success`、`failure`、`matched` |
| `Auto-terminate` | 讓某個 relationship 的 FlowFile 到此結束 | Processor 的 Relationships 分頁 |
| `Queue` | 等待下游處理的 FlowFile | Connection 上的數字 |
| `Back Pressure` | Queue 滿時壓住上游的保護機制 | Connection 設定 |
| `Controller Service` | 可共用的設定或資源 | Reader、Writer、DBCP |
| `Process Group` | 收納一組 flow 的資料夾 | Canvas 群組 |
| `Port` | Process Group 的入口或出口 | Input Port、Output Port |
| `Funnel` | 多條線合併成一條的匯流點 | Canvas 漏斗圖示 |
| `Bulletin` | UI 錯誤或警告提示 | Processor 右上角提示 |
| `Provenance` | FlowFile 歷史紀錄 | Data Provenance |
| `Parameter` | 可重複使用的設定值 | `#{parameter.name}` |
| `Record` | 結構化資料的一列 | CSV row、JSON object |
| `Schema` | Record 欄位與型別定義 | Reader/Writer 設定 |
| `Cluster` | 多個 NiFi node 共同執行同一份 flow | 公司正式環境、Summary |
| `Primary Node` | cluster 中被選為 primary 的 node | Processor `Execution`、Cluster 管理 |
| `Load Balanced Connection` | 把 queued FlowFile 分配到不同 node | Connection 設定 |

## 常用 Processor

| 類型 | Processor | 用途 |
| --- | --- | --- |
| 產生測試資料 | `GenerateFlowFile` | 建立練習用 FlowFile |
| 看 attributes/log | `LogAttribute` | 把 attributes 與 payload 寫到 log |
| 改 attributes | `UpdateAttribute` | 新增或修改 FlowFile metadata |
| attribute 路由 | `RouteOnAttribute` | 根據 Expression Language 分流 |
| 格式轉換 | `ConvertRecord` | 用 Reader/Writer 轉換 record 格式 |
| record 查詢 | `QueryRecord` | 用 SQL-like 語法篩選 record |
| record 更新 | `UpdateRecord` | 用 RecordPath 修改欄位 |
| record 驗證 | `ValidateRecord` | 檢查 record 是否符合 schema |
| 寫資料庫 | `PutDatabaseRecord` | 將 records 寫入 DB |
| 讀檔 | `GetFile` / `ListFile` + `FetchFile` | 讀取檔案來源 |
| 寫檔 | `PutFile` | 將 FlowFile content 寫出檔案 |

## 常用 Controller Service

| Service | 用途 |
| --- | --- |
| `CSVReader` | 讀取 CSV content 成 records |
| `CSVRecordSetWriter` | 將 records 寫成 CSV |
| `JsonTreeReader` | 讀取 JSON content 成 records |
| `JsonRecordSetWriter` | 將 records 寫成 JSON |
| `DBCPConnectionPool` | JDBC 連線池 |
| `AvroSchemaRegistry` | 管理 Avro schema |

## 常見 invalid 原因

| 訊息特徵 | 可能原因 | 處理 |
| --- | --- | --- |
| `Controller Service ... is disabled` | Reader/Writer/DBCP 沒 Enable | 到 Controller Services 啟用 |
| `Relationship ... is invalid` | relationship 未連線也未 auto-terminate | 連到下游或 auto-terminate |
| `required property is missing` | 必填 property 沒填 | 補值後 Apply |
| `Cannot write to database` | DB 連線、權限、表格或欄位錯 | 查 DBCP 與 DB log |
| `record.error.message` | Reader/Writer/schema 錯 | 查 failure queue attributes |

## 常用 Expression Language

```text
${filename:endsWith('.csv')}
${source.system:equals('training')}
${now():format("yyyyMMddHHmmss")}
${fileSize:ge(1000)}
${uuid}
```

## 常用 Formatter / Expression Language

| 需求 | 範例 |
| --- | --- |
| 字串取代 | `${field.value:replaceAll('phone=[0-9-]+', 'phone=***')}` |
| 日期格式轉換 | `${field.value:toDate('yyyy-MM-dd HH:mm:ss'):format('yyyy/MM/dd')}` |
| 補目前時間 | `${now():format("yyyy-MM-dd HH:mm:ss")}` |
| 轉大寫 | `${field.value:toUpper()}` |
| 去除前後空白 | `${field.value:trim()}` |

注意：在 `UpdateRecord` 裡，`field.value` 代表目前正在更新的 record 欄位值；它不是一般 FlowFile attribute。

## 常用 QueryRecord SQL

```sql
SELECT * FROM FLOWFILE
```

```sql
SELECT * FROM FLOWFILE WHERE "amount" >= 100
```

```sql
SELECT "order_id", "customer", "status" FROM FLOWFILE WHERE "status" = 'CANCELLED'
```

```sql
SELECT * FROM FLOWFILE WHERE "order_id" = 1003
```

注意：若 `CSVReader` 使用 `Infer Schema`，像 `order_id` 這種全數字欄位可能被推斷成數字，SQL 條件要用 `1003`。若 schema 明確定義成 string，才用 `'1003'`。

保留未命中資料時，建立另一個 relationship：

```sql
SELECT * FROM FLOWFILE WHERE "status" <> 'CANCELLED' OR "status" IS NULL
```

注意：`QueryRecord` 的 `original` 是完整原始 FlowFile，不是不符合條件的 records。不要把 `original` 當 unmatched 使用，否則可能重複處理 matched records。

## 常用 RecordPath

```text
/status
/customer
/amount
/items[*]/sku
```

UpdateRecord 常見搭配：

| RecordPath | Value |
| --- | --- |
| `/status` | `CANCELLED_NORMALIZED` |
| `/note` | `${field.value:replaceAll('phone=[0-9-]+', 'phone=***')}` |
| `/order_date` | `${field.value:toDate('yyyy-MM-dd HH:mm:ss'):format('yyyy/MM/dd')}` |

## Processor 排程速查

| 設定 | 用途 | 入門建議 |
| --- | --- | --- |
| `Scheduling Strategy = Timer driven` | 固定間隔執行 | 一般練習與簡單輪詢先用這個 |
| `Scheduling Strategy = CRON driven` | 指定時間點執行 | 公司批次排程常用 |
| `Run Schedule` | 執行頻率或 CRON 表達式 | 練習用 `30 sec` 或 `60 sec` |
| `Concurrent Tasks` | 同時執行緒數 | 新流程先用 `1` |
| `Execution = Primary Node` | cluster 中只在 Primary Node 執行 | 避免多節點重複抓同一批資料 |
| `Run Duration` | 延遲與吞吐量取捨 | 入門先維持預設 |

NiFi CRON 範例：

```text
0/30 * * * * ?        # 每 30 秒
0 0/5 * * * ?         # 每 5 分鐘
0 0 1 * * ?           # 每天凌晨 1 點
0 20 14 ? * MON-FRI   # 週一到週五 14:20
```

注意：NiFi CRON 有 seconds 欄位，不是 Linux crontab 常見的 5 欄格式。

## Cluster 速查

| 設定或名詞 | 用途 | 常見判斷 |
| --- | --- | --- |
| `Execution = All Nodes` | 每個 node 都會執行 Processor | 適合可分散處理的資料 |
| `Execution = Primary Node` | 只在 Primary Node 執行 Processor | 適合只應跑一次的排程來源 |
| `Load Balance Strategy = Do not load balance` | 不跨 node 分配 FlowFile | 預設較保守 |
| `Load Balance Strategy = Round robin` | 輪流分配到不同 node | 適合不依賴順序的資料 |
| `Load Balance Strategy = Partition by attribute` | 依 attribute 分配到固定 node | 適合同 key 需要在同 node 處理 |
| `Local state` | 每個 node 各自保存狀態 | 可能造成多 node 重複讀資料 |
| `Cluster state` | cluster 共用狀態 | 適合避免重複處理 |

公司 cluster 排程先問：這個來源是否只應執行一次？如果是，優先檢查 `Execution` 是否應為 `Primary Node`。

## Auto-terminate 速查

| 情境 | 建議 |
| --- | --- |
| 練習流程的最後一個 `success` | 可以 auto-terminate |
| `LogAttribute` 已經是最後觀察點 | 可以 auto-terminate `success` |
| `failure` | 不建議一開始 auto-terminate，先接錯誤處理或 `LogAttribute` |
| `unmatched` | 先確認是否代表漏接資料，再決定是否 auto-terminate |
| `original` | 確認不需要原始 FlowFile 後再 auto-terminate |

一句話：auto-terminate 代表這個 relationship 的 FlowFile 到此結束，不是萬用的錯誤忽略開關。

延伸閱讀：[Auto-terminate 完整說明](supplement-auto-terminate.md)

## 日常 Docker 指令

以下指令都在專案根目錄執行，也就是目前包含 `docker-compose.yaml` 的工作目錄。

```powershell
docker compose ps
docker compose stop
docker compose start
docker compose logs --tail=200 nifi
docker compose logs -f nifi
```

避免：

```powershell
docker compose down -v
docker volume prune
```

## 排錯順序

1. 看 Processor 是否 invalid。
2. 看 bulletin。
3. 看 queue 是否累積。
4. 打開 queue 檢查 FlowFile attributes/content。
5. 查 provenance。
6. 查 `docker compose logs --tail=200 nifi`。
7. 查 Controller Service 狀態。
8. 對照 schema、欄位名稱、relationship。

## 這份速查表的使用方式

這份不是照順序學習的 Lab，而是你做 Lab 或看公司 flow 時用來快速查名詞與排錯方向。

建議使用方式：

- 看不懂 UI 名詞時，先查「基本名詞速查」。
- 不知道該用哪個元件時，查「常用 Processor」與「常用 Controller Service」。
- Processor 顯示 invalid 時，先查「常見 invalid 原因」。
- 需要排程時，查「Processor 排程速查」。
- 資料卡住或結果不對時，照「排錯順序」從上往下檢查。

如果你在公司專案看到一條陌生 flow，先不要急著改設定。先找出資料從哪個 Processor 進來、經過哪些 connection、卡在哪個 queue、失敗 relationship 有沒有被處理，再決定要看 Processor 設定、Controller Service，還是 provenance。
