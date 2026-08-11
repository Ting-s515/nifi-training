# NiFi Custom Processor SPI 範例

這個範例使用 NiFi 2.9.0 的公開 Java API，建立一個可部署、包含兩個客製化
Processor 的 Bundle：

```text
同一個 JAR/NAR
        ├─ ValidateOrderJsonProcessor
        │      ├─ success → LogAttribute
        │      └─ failure → LogAttribute
        └─ OrderPolicyProcessor
               ├─ approved → LogAttribute
               ├─ manual-review → LogAttribute
               ├─ rejected → LogAttribute
               └─ failure → LogAttribute
```

自訂 Processor 透過 `RecordReaderFactory` 使用 `JsonTreeReader` 將 JSON 讀成 Record，
`ValidateOrderJsonProcessor` 負責驗證 `order_id`、`customer`、`amount`，
`OrderPolicyProcessor` 則依 `customer_tier` 與 `amount` 執行公司政策決策。兩者都保留
原始 content，並寫入固定 attributes。這個設計比直接在 Processor 內呼叫 JSON library
更接近 NiFi 的公開 extension API，也能把 Reader 替換成其他格式的 Controller Service。

## 目錄

- `nifi-training-custom-processor-processors/`：Processor Java 原始碼、ServiceLoader
  descriptor 與兩個 Processor 的 `nifi-mock` 測試。
- `nifi-training-custom-processor-nar/`：將 Processor JAR 打包成 NiFi 可載入的 NAR。
- `scripts/nifi-flow-helper.ps1`：共用 NiFi REST、Queue、NAR 與 cleanup 操作。
- `scripts/setup-flow.ps1`：以 NiFi REST API 上傳 NAR、建立 `JsonTreeReader`、建立
  驗證 Process Group 並驗證三種資料案例。
- `scripts/setup-policy-flow.ps1`：建立政策 Process Group 並驗證五種政策案例。
- `build.ps1`：使用 Docker Maven + JDK 21 建置，避免依賴主機 Maven 版本。

## 建置

在 repository 根目錄執行：

```powershell
.\examples\nifi-custom-processor\build.ps1
```

若只想重新執行驗證、不清除 `target/`：

```powershell
.\examples\nifi-custom-processor\build.ps1 -SkipClean
```

成功後的產物：

```text
examples/nifi-custom-processor/nifi-training-custom-processor-processors/target/nifi-training-custom-processor-processors-2.1.0.jar
examples/nifi-custom-processor/nifi-training-custom-processor-nar/target/nifi-training-custom-processor-nar-2.1.0.nar
```

這個範例要求 Java 21 的編譯目標，實際 Maven 執行放在 Docker 的 Maven + JDK 21
映像中；第一次執行會下載映像與 Maven 相依套件。

## 透過 REST API 建立測試 Flow

先確認根目錄 `.env` 已有本機 NiFi 帳密，且 NiFi 已啟動：

```powershell
docker compose up -d
```

完成建置後執行：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1
```

腳本會依序：

1. 取得 `POST /access/token` 的 Bearer token。
2. 以 `POST /controller/nar-manager/nars/content` 上傳 2.1.0 NAR。
3. 輪詢 NAR 安裝狀態，並用 `GET /flow/processor-types` 驗證 Processor 已註冊。
4. 用 `GET /flow/controller-service-types` 找到 `JsonTreeReader`，建立並啟用
   `RecordReaderFactory` Controller Service。
5. 設定明確的 Avro schema，讓缺少欄位的 JSON 先轉成 nullable Record，再交給自訂
   Processor 執行商業規則驗證。
6. 建立三個 `GenerateFlowFile` 測試來源、驗證 Processor 與兩個 `LogAttribute`。
7. 以 REST API 建立三條輸入連線，以及 `success`、`failure` 兩條分流連線。
8. 逐筆使用 `RUN_ONCE` 執行，從 Queue 與 FlowFile API 驗證 status、reason 與原始
   content。

驗證流程的三個案例預期結果：

| 案例 | 預期關係 | `training.validation.status` | `training.validation.reason` |
| --- | --- | --- | --- |
| 完整訂單 | `success` | `valid` | `accepted` |
| 缺少 `customer` | `failure` | `invalid` | `customer.required` |
| `amount = 0` | `failure` | `invalid` | `amount.positive` |

預設不會刪除建立的 Process Group，方便回到 UI 觀察 Controller Service、Processor、
queue 與 bulletin。若 NAR 已經安裝，可略過上傳並使用新的 group name：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1 `
  -SkipNarUpload `
  -GroupName training-lab-11-json-validation-rerun
```

練習完成後可以讓腳本驗證並刪除本次建立的 Process Group：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1 `
  -GroupName training-lab-11-json-validation-cleanup `
  -Cleanup
```

如果 root 下已經有相同名稱的課程 Process Group，可明確指定替換：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1 `
  -ReplaceExisting
```

`-ReplaceExisting` 會依同名群組取得 ID，停止其中的 Processor、清空 Queue、停用
Controller Service、刪除舊群組，再建立同名的新群組。這是破壞性操作；若同名群組超過一個，
腳本會停止並列出 ID，避免誤刪錯誤流程。

NAR 已安裝後，建立獨立的政策 Process Group：

```powershell
.\examples\nifi-custom-processor\scripts\setup-policy-flow.ps1 `
  -SkipNarUpload `
  -GroupName training-lab-11-order-policy
```

政策流程會建立五個測試來源與四個輸出 `LogAttribute`，驗證：

| 案例 | Relationship | `training.policy.decision` | `training.policy.reason` |
| --- | --- | --- | --- |
| standard、amount `800` | `approved` | `approved` | `accepted` |
| vip、amount `4500` | `approved` | `approved` | `accepted` |
| standard、amount `1500` | `manual-review` | `manual_review` | `tier.amount.review` |
| vip、amount `6000` | `rejected` | `rejected` | `amount.limit` |
| 缺少 `customer_tier` | `failure` | `error` | `customer_tier.required` |

`OrderPolicyProcessor` 的預設 properties 是：

| Property | 預設值 |
| --- | --- |
| `Manual Review Threshold` | `1000` |
| `Reject Threshold` | `5000` |
| `VIP Customer Tier` | `vip` |

兩支 setup script 都支援 `-SkipNarUpload`、`-GroupName`、`-ReplaceExisting` 與
`-Cleanup`。預設只清除驗證過程讀回的 queue；指定 `-Cleanup` 才會刪除該次建立的
Process Group。`-ReplaceExisting` 只應用在課程測試群組，正式流程應先備份或確認 Queue
資料已不再需要。

## Processor API 對照

| 課程概念 | 範例位置或責任 |
| --- | --- |
| `AbstractProcessor` | 兩個客製化 Processor 的基底類別 |
| `PropertyDescriptor` | Reader 與政策門檻的 NiFi 設定 contract |
| `Relationship` | 驗證的 `success/failure` 與政策的四條輸出 |
| `ProcessContext` | 取得 `RecordReaderFactory` |
| `ProcessSession` | 讀取 FlowFile、保留 content、寫入 attributes、轉送 FlowFile |
| `RecordReaderFactory` | NiFi 公開的 Record 讀取契約 |
| `JsonTreeReader` | 將 JSON FlowFile 解析成 `Record` 的 Controller Service |
| ServiceLoader 註冊 | `META-INF/services/org.apache.nifi.processor.Processor` |
| 單元測試 | `TestRunners.newTestRunner`、`MockFlowFile`、真實 `JsonTreeReader` |
| 可部署封裝 | `nifi-training-custom-processor-nar` |

課程只依賴 NiFi 公開 API、Record serialization service 與 NAR Maven plugin；不依賴
UI 內部 class、瀏覽器操作或 Python script，方便將 Processor 邏輯搬到公司專案後繼續
維護。

## 驗證規則

`ValidateOrderJsonProcessor` 將格式解析與商業驗證分開：

- JSON 無法解析、schema 找不到或同一 FlowFile 包含多筆 record：`error` 或
  `invalid`，原因為 `record-reader.error` 或 `record.count`。
- `order_id`、`customer` 缺少或空白：產生對應的 `.required` 或 `.blank` code。
- `amount` 缺少、不是數字或小於等於零：產生 `.required`、`.numeric` 或 `.positive`
  code。
- 多個商業錯誤會依 `order_id`、`customer`、`amount` 順序以分號合併，方便下游記錄與
  測試比對。

`OrderPolicyProcessor` 將公司政策封裝成可配置的 Processor contract：

- `amount > 5000`：`rejected`，reason `amount.limit`。
- `amount > 1000` 且 `customer_tier` 不是 `vip`：`manual-review`，reason
  `tier.amount.review`。
- 其他合法資料：`approved`，reason `accepted`。
- 欄位缺少、型別錯誤、JSON 解析失敗或多筆 Record：`failure`。

這兩個 class 放在同一個 processors JAR，再由同一個 NAR 部署；學員不需要為每個
Processor 強制建立一個獨立 JAR。NiFi 仍會依 ServiceLoader descriptor 將兩個 class
註冊成兩個可建立的 Processor type。

完整的課程背景、SPI、JAR、NAR 與 REST API 操作請閱讀：

```text
docs/nifi-training/11-00-custom-processor-spi.md
```
