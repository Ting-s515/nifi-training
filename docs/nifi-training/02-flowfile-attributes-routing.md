# Lab 02：FlowFile、Attribute、Expression Language 與路由

目標：理解 FlowFile 由 content 與 attributes 組成，並用 Expression Language 依 attribute 分流。

預估時間：30 分鐘。

## 你會做出什麼

```mermaid
flowchart LR
    G[GenerateFlowFile] --> U[UpdateAttribute]
    U --> R[RouteOnAttribute]
    R --> L[LogAttribute]
```

## Step 1：建立 Process Group

建立 `training-lab-02`，進入該 Process Group。

## Step 2：新增 GenerateFlowFile

設定：

- `Run Schedule`：`60 sec`
- `Custom Text`：

```csv
order_id,customer,amount,status
1001,Alice,120.50,NEW
1002,Bob,35.00,CANCELLED
```

## Step 3：新增 UpdateAttribute

新增 Processor：`UpdateAttribute`。

在 `Properties` 新增 dynamic properties：

| Property | Value |
| --- | --- |
| `source.system` | `training` |
| `data.kind` | `orders` |
| `filename` | `orders-${now():format("yyyyMMddHHmmss")}.csv` |

說明：Attribute 是 FlowFile 的 metadata。公司專案常用它保存來源系統、檔名、批次號、schema 名稱、錯誤原因。

## Step 4：新增 RouteOnAttribute

新增 Processor：`RouteOnAttribute`。

設定：

- `Routing Strategy`：`Route to Property name`

新增 dynamic property：

| Property | Value |
| --- | --- |
| `csv_orders` | `${filename:endsWith('.csv')}` |

RouteOnAttribute 會依 dynamic property 產生同名 relationship，例如 `csv_orders`。

## Step 5：新增 LogAttribute

新增 Processor：`LogAttribute`。

設定：

- `Log Prefix`：`lab02`
- `Log Payload`：`true`

## Step 6：連線與 relationship

連線：

```mermaid
flowchart LR
    G[GenerateFlowFile] -- success --> U[UpdateAttribute]
    U -- success --> R[RouteOnAttribute]
    R -- csv_orders --> L[LogAttribute]
```

Auto-terminate：

- `RouteOnAttribute` 的 `unmatched`
- `LogAttribute` 的 `success`

## Step 7：執行與觀察

1. 全選 Processor，按 Start。
2. 等一筆資料通過後，停止 `GenerateFlowFile`。
3. 查看 log：

```powershell
docker compose logs --tail=160 nifi
```

4. 到 NiFi UI 打開 provenance，搜尋最近 FlowFile。
5. 觀察 attributes 是否包含：
   - `source.system`
   - `data.kind`
   - `filename`
   - `RouteOnAttribute.Route`

## 練習題

1. 把 `data.kind` 改成 `customers`，確認資料會走 `unmatched`。
2. 新增一條 route：

| Property | Value |
| --- | --- |
| `orders_data` | `${data.kind:equals('orders')}` |

3. 觀察如果一筆 FlowFile 同時符合多條 route，NiFi 如何處理 relationship。

## 完成檢查

- 你能分辨 FlowFile content 與 attributes。
- 你能用 `UpdateAttribute` 新增 metadata。
- 你能用 `RouteOnAttribute` 依 attribute 分流。
- 你知道 `unmatched` 沒處理時會造成 invalid 或資料卡住。

## 本 Lab 的學習重點回顧

這個 Lab 建立的是 attribute-based routing：

```mermaid
flowchart LR
    G[GenerateFlowFile] --> U[UpdateAttribute]
    U --> R[RouteOnAttribute]
    R -- csv_orders --> L[LogAttribute]
```

整個流程的意思是：

1. `GenerateFlowFile` 產生一筆 CSV 文字資料。
2. `UpdateAttribute` 不改 CSV 內容，只幫 FlowFile 加上 metadata，例如 `source.system`、`data.kind`、`filename`。
3. `RouteOnAttribute` 不看 CSV 欄位，而是看 FlowFile attributes。
4. 如果 attributes 符合條件，例如檔名是 `.csv`，資料就走到 `csv_orders` relationship。
5. `LogAttribute` 把最後的 FlowFile 狀態寫到 log，讓你確認 route 是否正確。

這個 Lab 模擬公司專案常見情境：資料進來後，先補上來源、類型、批次資訊，再根據 metadata 決定資料要走哪條流程。

做完後你要理解：

- Attributes 是 FlowFile 的外層標籤，適合拿來做路由、批次追蹤、錯誤原因保存。
- `RouteOnAttribute` 適合依 metadata 分流，不適合直接查 CSV 裡的欄位值。
- 如果你要依 CSV 欄位內容分流，後面會用 `QueryRecord` 或 Record 相關 Processor。
