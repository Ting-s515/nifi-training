# Lab 08：Processor 排程與執行控制

目標：理解 NiFi Processor 的 `Scheduling` 分頁，能設定固定間隔排程、CRON 排程、併發數與執行節點策略。

預估時間：45 分鐘。

## 你會做出什麼

本 Lab 會建立兩條小流程：

```text
Timer driven: GenerateFlowFile -> UpdateAttribute -> LogAttribute
CRON driven:  GenerateFlowFile -> UpdateAttribute -> LogAttribute
```

第一條用固定間隔執行；第二條用 CRON 表達式模擬公司常見的批次排程。

## 官方確認的排程概念

NiFi 官方 User Guide 說明 Processor 的 `Scheduling` 分頁包含：

- `Scheduling Strategy`
- `Concurrent Tasks`
- `Run Schedule`
- `Execution`
- `Run Duration`

`Timer driven` 是預設模式，依 `Run Schedule` 固定間隔執行。`CRON driven` 也是週期性執行，但用 CRON 表達式提供更精細的時間控制。

官方文件也說明 `CRON driven` 的排程字串包含 6 個必要欄位與 1 個選用欄位：

```text
Seconds Minutes Hours Day-of-Month Month Day-of-Week Year(optional)
```

來源：https://nifi.apache.org/nifi-docs/user-guide.html

## Part 1：建立 Process Group

建立 `training-lab-08`，進入該 Process Group。

## Part 2：Timer Driven 固定間隔排程

### Step 1：新增 GenerateFlowFile

新增 Processor：`GenerateFlowFile`。

設定 `Properties`：

| Property | Value |
| --- | --- |
| `Custom Text` | `timer driven test` |

設定 `Scheduling`：

| Setting | Value |
| --- | --- |
| `Scheduling Strategy` | `Timer driven` |
| `Run Schedule` | `30 sec` |
| `Concurrent Tasks` | `1` |

### Step 2：新增 UpdateAttribute

新增 Processor：`UpdateAttribute`。

新增 dynamic properties：

| Property | Value |
| --- | --- |
| `schedule.type` | `timer` |
| `schedule.fired.at` | `${now():format("yyyy-MM-dd HH:mm:ss")}` |

### Step 3：新增 LogAttribute

新增 Processor：`LogAttribute`。

設定：

| Property | Value |
| --- | --- |
| `Log Prefix` | `lab08-timer` |
| `Log Payload` | `true` |

### Step 4：連線

```text
GenerateFlowFile success -> UpdateAttribute
UpdateAttribute success -> LogAttribute
```

Auto-terminate：

- `LogAttribute` 的 `success`

### Step 5：執行與觀察

1. 啟動三個 Processor。
2. 等 1 至 2 次排程觸發。
3. 停止 `GenerateFlowFile`。
4. 查看 log：

```powershell
docker compose logs --tail=160 nifi
```

你應該看到 `lab08-timer` 與 `schedule.fired.at`。

## Part 3：CRON Driven 指定時間排程

### Step 1：複製第一條流程

1. 複製 Part 2 的三個 Processor。
2. 貼到同一個 Process Group 旁邊。
3. 將新的 `LogAttribute` 的 `Log Prefix` 改成：

```text
lab08-cron
```

4. 將新的 `UpdateAttribute` 裡 `schedule.type` 改成：

```text
cron
```

### Step 2：設定 CRON

打開第二個 `GenerateFlowFile` 的 `Scheduling`。

設定：

| Setting | Value |
| --- | --- |
| `Scheduling Strategy` | `CRON driven` |
| `Run Schedule` | `0/30 * * * * ?` |
| `Concurrent Tasks` | `1` |

這個 CRON 表達式代表每 30 秒觸發一次，適合練習觀察。正式公司排程不建議用這麼密。

常見範例：

| 需求 | NiFi CRON |
| --- | --- |
| 每 30 秒 | `0/30 * * * * ?` |
| 每 5 分鐘 | `0 0/5 * * * ?` |
| 每天凌晨 1 點 | `0 0 1 * * ?` |
| 每週一到週五 14:20 | `0 20 14 ? * MON-FRI` |

注意：NiFi 使用的 CRON 有秒欄位，和 Linux crontab 常見的 5 欄格式不同。

### Step 3：執行與觀察

1. 啟動第二條流程。
2. 等 CRON 觸發。
3. 查看 log：

```powershell
docker compose logs --tail=220 nifi
```

4. 停止第二個 `GenerateFlowFile`。

## Part 4：Concurrent Tasks 併發數

`Concurrent Tasks` 控制 Processor 同時使用多少執行緒處理資料。提高此值可能增加吞吐量，但也會消耗更多系統資源，並可能讓下游壓力變大。

練習：

1. 建立 `GenerateFlowFile -> LogAttribute`。
2. 將 `GenerateFlowFile` 設定為：

| Setting | Value |
| --- | --- |
| `Scheduling Strategy` | `Timer driven` |
| `Run Schedule` | `0 sec` |
| `Concurrent Tasks` | `1` |

3. 啟動 5 秒後停止，觀察產生多少 FlowFile。
4. 清空 queue。
5. 將 `Concurrent Tasks` 改成 `2`。
6. 再啟動 5 秒後停止。
7. 比較 queue 與 log。

結論：`0 sec` 代表盡可能執行，不適合作為新手練習或低頻公司批次排程的預設值。

## Part 5：Run Duration

`Run Duration` 是延遲與吞吐量的取捨：

- 越偏低延遲：每次觸發後較快交棒給下游。
- 越偏高吞吐：每次觸發做更多工作後再更新 repository。

入門階段建議先維持預設值。只有在資料量大、確認瓶頸後，再調整。

## Part 6：Execution 與 Primary Node

如果 NiFi 是 cluster，`Execution` 會影響 Processor 在哪些節點執行：

| Execution | 意義 |
| --- | --- |
| `All Nodes` | 每個節點都會執行 |
| `Primary Node` | 只在 Primary Node 執行 |

公司常見判斷：

- 讀取共用 DB 或共用 API 的排程，常需要避免多節點重複抓資料。
- 若是 cluster 且來源不支援多節點並行，應評估 `Primary Node`。
- 若每個節點處理各自本機資料，才可能使用 `All Nodes`。

目前你的本機 Docker 是單節點環境，這一段先理解概念即可。

## Part 7：公司專案排程檢查清單

新增或修改排程前，先確認：

- 排程是固定間隔還是指定時間點。
- 是否允許重疊執行。
- 上一次還沒跑完時，下一次觸發要怎麼處理。
- `Concurrent Tasks` 是否會造成重複讀取、重複寫入或資料競爭。
- 來源系統是否有 rate limit。
- 目標系統是否能承受尖峰寫入。
- 失敗資料要重試、告警、還是進錯誤佇列。
- 是否需要用 attribute 記錄批次時間，例如 `batch.date`、`batch.id`。
- CRON 時區是否符合公司排程約定。

## 常見錯誤

### 排程太密

現象：

- queue 快速累積。
- CPU 或 disk IO 上升。
- 下游 DB/API 開始 timeout。

處理：

- 拉長 `Run Schedule`。
- 降低 `Concurrent Tasks`。
- 加上 back pressure。
- 先確認下游瓶頸再調整。

### CRON 格式錯誤

現象：

- Processor invalid。
- `Run Schedule` 顯示格式錯誤。

處理：

- 確認 NiFi CRON 是 6 欄起跳，第一欄是 seconds。
- 不要直接貼 Linux crontab 的 5 欄格式。

### 多節點重複執行

現象：

- 公司排程本來一天一批，結果 cluster 每個節點都跑一次。

處理：

- 檢查 `Execution`。
- 對只應執行一次的排程，評估 `Primary Node`。

## 完成檢查

- 你能設定 `Timer driven` 固定間隔排程。
- 你能設定 `CRON driven` 指定時間排程。
- 你知道 NiFi CRON 和 Linux crontab 欄位數不同。
- 你知道 `Concurrent Tasks` 會影響併發與資源使用。
- 你知道 cluster 下 `Execution` 可能造成多節點重複執行。
- 你知道公司排程要考慮重疊執行、下游承載與錯誤處理。
