# Lab 00：NiFi 基本名詞導讀

目標：先看懂 NiFi UI 常見名詞，避免進入實作 Lab 時不知道畫面上的字代表什麼。

預估時間：25 分鐘。

這份不是純字典。每個名詞都會用三個角度說明：

- 你在 UI 哪裡看到它。
- 它在資料流中代表什麼。
- 實作時最常踩到什麼問題。

## 一張圖先看整體

```text
Process Group
└─ Processor A -- relationship --> Connection Queue -- relationship --> Processor B
       │                                                       │
       │                                                       └─ FlowFile 等待下游處理
       │
       └─ 使用 Controller Service，例如 CSVReader、DBCPConnectionPool
```

NiFi 的基本想法是：資料被包成 `FlowFile`，沿著 `Processor` 之間的 `Connection` 往下游移動。每個 Processor 處理完後，會把資料丟到不同 `Relationship`，例如 `success`、`failure`、`matched`、`unmatched`。

## FlowFile

你可以把 `FlowFile` 想成 NiFi 裡的一筆資料包裹。

它包含兩部分：

| 部分 | 說明 | 範例 |
| --- | --- | --- |
| Content | 真正的資料內容 | CSV、JSON、XML、binary file |
| Attributes | metadata | `filename`、`uuid`、`mime.type`、`record.count` |

你在 UI 哪裡看到：

- Queue 的 `List queue`
- Provenance event details
- `LogAttribute` 的 log

常見誤解：

- `UpdateAttribute` 改的是 attributes，不會改 CSV/JSON 內容。
- `UpdateRecord`、`ConvertRecord`、`QueryRecord` 才是在處理 content 裡的 records。

## Processor

`Processor` 是 NiFi 的處理節點。

常見 Processor：

| Processor | 用途 |
| --- | --- |
| `GenerateFlowFile` | 產生測試資料 |
| `LogAttribute` | 印出 FlowFile attributes/content |
| `UpdateAttribute` | 修改 attributes |
| `RouteOnAttribute` | 根據 attributes 分流 |
| `ConvertRecord` | 用 Reader/Writer 轉換格式 |
| `QueryRecord` | 查詢 content 裡的 records |
| `PutDatabaseRecord` | 寫入資料庫 |

你在 UI 哪裡看到：

- Canvas 上的方塊。
- Processor 設定裡的 `Settings`、`Scheduling`、`Properties`、`Relationships`。

常見問題：

- Processor 顯示 invalid，多半是必填 property 沒填、relationship 沒處理、Controller Service disabled。
- Processor stopped 不代表壞掉，只是目前不執行。
- Processor running 也不代表有資料處理，要看 queue 與 stats。

## Connection

`Connection` 是 Processor 之間的線。

它代表：

- 上游資料要送到哪個下游。
- 哪些 relationship 會走這條線。
- 中間 queue 的保存位置。

你在 UI 哪裡看到：

- Processor 之間的連線。
- 線上顯示的 queue 數量與資料大小。

常見問題：

- Connection 上 queue 數字一直增加，表示下游處理不完、下游停止、下游 invalid，或排程太慢。
- Connection 可以設定 back pressure，避免資料無限制累積。

## Relationship

`Relationship` 是 Processor 處理結果的出口名稱。

常見 relationship：

| Relationship | 意義 |
| --- | --- |
| `success` | 成功 |
| `failure` | 失敗 |
| `matched` | 符合條件 |
| `unmatched` | 不符合條件 |
| `original` | 原始 FlowFile |

你在 UI 哪裡看到：

- 建立 connection 時要選 relationship。
- Processor 設定的 `Relationships` 分頁。

常見問題：

- 每個 relationship 都要連出去或 auto-terminate。
- 忘記處理 `failure`，錯誤資料可能卡住或 Processor invalid。
- `QueryRecord` 這類 Processor 可能會產生 dynamic relationship。

## Queue

`Queue` 是 Connection 裡等待被下游處理的 FlowFile。

你在 UI 哪裡看到：

- Connection 上的數字，例如 `3 (12 KB)`。
- 右鍵 connection 可進入 `List queue`。

你可以做什麼：

- 看 FlowFile attributes。
- 看 content。
- 刪除測試資料。
- 在排錯時確認資料卡在哪裡。

常見問題：

- 新手常以為資料不見了，其實只是停在 queue。
- 下游 Processor 沒有 start，queue 就會累積。
- 排程太密或 concurrent tasks 太高，也可能讓 queue 快速累積。

## Back Pressure

`Back Pressure` 是 queue 的保護機制。

它可以設定：

- 最多幾筆 FlowFile。
- 最多多少資料大小。

達到門檻後，上游會被壓住，避免整個 NiFi 被資料塞爆。

你在 UI 哪裡看到：

- Connection 設定。
- Queue 滿時，connection 會有明顯提示。

實務觀念：

- Back pressure 不是錯誤，它是保護。
- 如果常常觸發 back pressure，要查下游效能、排程頻率、DB/API 速度。

## Controller Service

`Controller Service` 是可被多個 Processor 共用的設定或資源。

常見 Controller Service：

| Service | 用途 |
| --- | --- |
| `CSVReader` | 讀 CSV 成 records |
| `CSVRecordSetWriter` | 把 records 寫成 CSV |
| `JsonTreeReader` | 讀 JSON 成 records |
| `DBCPConnectionPool` | DB 連線池 |

你在 UI 哪裡看到：

- Process Group 的 `Configure` > `Controller Services`。
- Processor properties 裡選 Reader、Writer、DBCP。

常見問題：

- Controller Service 必須 `Enabled`，Processor 才能使用。
- 改 service 設定前，通常要先 disable。
- 不同 Process Group 的 service 範圍不同，要確認 Processor 是否選到正確那個。

## Process Group

`Process Group` 是用來收納一組 Processor 的資料流資料夾。

你在 UI 哪裡看到：

- Canvas 上可進入的群組。
- 公司專案通常會用 Process Group 切功能、來源系統或批次流程。

實務用途：

- 讓大 flow 不會全部攤在 root canvas。
- 可以針對一整組 flow 做版本管理。
- 可以設定該群組自己的 Controller Services。

建議：

- 每個功能或資料來源建一個清楚命名的 Process Group。
- 練習課程用 `training-lab-xx`，避免和公司流程混在一起。

## Port

`Port` 是 Process Group 的入口或出口。

常見類型：

| Port | 用途 |
| --- | --- |
| Input Port | 讓外層資料進入 Process Group |
| Output Port | 讓 Process Group 內資料送回外層 |

你在 UI 哪裡看到：

- Process Group 內外連線時。
- 大型 flow 拆多層時。

實務觀念：

- Port 可以讓 Process Group 像模組一樣被串接。
- 命名要清楚，例如 `raw-orders-in`、`valid-orders-out`、`failed-orders-out`。

## Funnel

`Funnel` 是匯流點，用來把多條 connection 合併成一條。

你在 UI 哪裡看到：

- Canvas 上的小漏斗圖示。

實務觀念：

- Funnel 不處理資料，只整理線路。
- 多個 Processor 的 failure 都要送到同一條錯誤流程時很常用。

## Bulletin

`Bulletin` 是 NiFi UI 上的錯誤或警告提示。

你在 UI 哪裡看到：

- Processor 右上角的小提示 icon。
- Bulletin board。

常見內容：

- Controller Service disabled。
- DB connection failed。
- schema 不符合。
- file path 不存在。
- 權限錯誤。

排錯方式：

1. 先看 bulletin 文字。
2. 找出 Processor 名稱與錯誤關鍵字。
3. 再看 queue、provenance、logs。

## Data Provenance

`Data Provenance` 是資料流經歷史紀錄。

它能回答：

- 這筆資料從哪裡來。
- 經過哪些 Processor。
- 哪一步修改了 attributes 或 content。
- 哪一步失敗。

你在 UI 哪裡看到：

- 右上角 Global Menu 的 `Data Provenance`。
- Processor 右鍵也能看相關 provenance。

實務用途：

- 查 production 資料問題。
- 比對轉換前後 content。
- 找出資料在哪一步被 route 到 failure。

## Parameter / Parameter Context

`Parameter` 是可重複使用的設定值。

常見用途：

- DB host
- schema name
- API URL
- S3 bucket
- batch size

你在 UI 哪裡看到：

- Parameter Context 設定。
- Processor property 裡使用 `#{parameter.name}`。

實務觀念：

- 不同環境可以用不同 Parameter Context，例如 dev、staging、prod。
- 帳密或敏感值要依公司規範管理，不要寫在文件或 commit。

## Record

`Record` 是 NiFi 對結構化資料的一列資料的抽象。

例如 CSV：

```csv
order_id,customer,amount
1001,Alice,120.50
1002,Bob,35.00
```

這裡有兩筆 records。

常見 Record Processor：

- `ConvertRecord`
- `QueryRecord`
- `UpdateRecord`
- `ValidateRecord`
- `PutDatabaseRecord`

實務觀念：

- Record Processor 通常需要 Record Reader 與 Record Writer。
- `record.count` attribute 常用來確認處理幾筆資料。

## Schema

`Schema` 描述 record 的欄位與型別。

範例：

```text
order_id: string
customer: string
amount: decimal
```

你在 UI 哪裡看到：

- `CSVReader`、`JsonTreeReader`、Record Writer 的設定。
- Schema Registry 或 Avro schema 設定。

常見問題：

- CSV header 與 schema 欄位名稱不一致。
- 金額被讀成 string，導致 QueryRecord 比較結果不如預期。
- Writer schema 不包含新增欄位，導致 UpdateRecord 結果沒有輸出該欄位。

## Expression Language

`Expression Language` 是 NiFi 用來操作 attributes 的語法。

範例：

```text
${filename:endsWith('.csv')}
${now():format("yyyyMMddHHmmss")}
${source.system:equals('training')}
```

常用位置：

- `UpdateAttribute`
- `RouteOnAttribute`
- Processor property

注意：

- Expression Language 通常處理 attributes，不是直接查 CSV/JSON 欄位。
- 要查 record 欄位，通常用 QueryRecord、UpdateRecord 或 RecordPath。

## RecordPath

`RecordPath` 是 NiFi 用來定位 record 欄位的語法。

範例：

```text
/status
/customer
/items[*]/sku
```

常用位置：

- `UpdateRecord`
- `QueryRecord` 相關設定
- Record validation 或轉換場景

## Scheduling

`Scheduling` 是 Processor 什麼時候執行、怎麼執行的設定。

常見設定：

| 設定 | 說明 |
| --- | --- |
| `Timer driven` | 固定間隔執行 |
| `CRON driven` | 指定時間點執行 |
| `Run Schedule` | 執行頻率或 CRON |
| `Concurrent Tasks` | 同時執行緒數 |
| `Execution` | cluster 中在哪些節點執行 |

常見問題：

- `Run Schedule = 0 sec` 代表盡可能執行，容易產生大量測試資料。
- 公司批次排程常用 `CRON driven`。
- cluster 中要注意 `All Nodes` 可能造成多節點重複執行。

## State

`State` 是 Processor 或 NiFi 用來記錄執行進度的狀態資料。

常見例子：

- `ListFile` 記住哪些檔案已列過。
- 某些來源 Processor 記住上次讀取位置。

實務觀念：

- State 和 FlowFile content 不一樣。
- 重建環境、清 state、刪 volume 都可能影響資料是否重複抓取。
- 這也是為什麼本專案要使用 Docker named volumes 保存 `state`。

## 一分鐘總結

先記住這條線：

```text
FlowFile 在 Processor 之間移動，Connection 裡有 Queue，Processor 用 Relationship 決定資料往哪裡走。
```

再記住這三個排錯入口：

```text
Bulletin 看錯誤，Queue 看資料卡在哪，Provenance 看資料走過哪裡。
```

最後記住 Controller Service：

```text
Reader、Writer、DBCP 這類共用設定要先 Enable，Processor 才能正常使用。
```
