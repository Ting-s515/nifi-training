# Lab 02：FlowFile、Attribute、Expression Language 與路由

目標：理解 FlowFile 由 content 與 attributes 組成，並用 Expression Language 依 attribute 分流。

預估時間：30 分鐘。

## 你會做出什麼

```text
GenerateFlowFile -> UpdateAttribute -> RouteOnAttribute -> LogAttribute
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

```text
GenerateFlowFile success -> UpdateAttribute
UpdateAttribute success -> RouteOnAttribute
RouteOnAttribute csv_orders -> LogAttribute
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
