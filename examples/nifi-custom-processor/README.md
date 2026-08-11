# NiFi Custom Processor SPI 範例

這個範例使用 NiFi 2.9.0 的公開 Java API，建立一個可部署的 JSON 訂單驗證
Processor Bundle：

```text
GenerateFlowFile (3 個案例)
        │
        ▼
ValidateOrderJsonProcessor
        │
        ├─ success → LogAttribute
        └─ failure → LogAttribute
```

自訂 Processor 透過 `RecordReaderFactory` 使用 `JsonTreeReader` 將 JSON 讀成 Record，
再驗證 `order_id`、`customer`、`amount` 三個必要欄位。成功與失敗都保留原始 content，
並寫入 `training.validation.status` 與 `training.validation.reason` attributes。這個
設計比直接在 Processor 內呼叫 JSON library 更接近 NiFi 的公開 extension API，也能把
Reader 替換成其他格式的 Controller Service。

## 目錄

- `nifi-training-custom-processor-processors/`：Processor Java 原始碼、ServiceLoader
  descriptor 與 `nifi-mock` 測試。
- `nifi-training-custom-processor-nar/`：將 Processor JAR 打包成 NiFi 可載入的 NAR。
- `scripts/setup-flow.ps1`：以 NiFi REST API 上傳 NAR、建立 `JsonTreeReader`、建立
  測試 Process Group 並驗證三種資料案例。
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
examples/nifi-custom-processor/nifi-training-custom-processor-processors/target/nifi-training-custom-processor-processors-2.0.0.jar
examples/nifi-custom-processor/nifi-training-custom-processor-nar/target/nifi-training-custom-processor-nar-2.0.0.nar
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
2. 以 `POST /controller/nar-manager/nars/content` 上傳 2.0.0 NAR。
3. 輪詢 NAR 安裝狀態，並用 `GET /flow/processor-types` 驗證 Processor 已註冊。
4. 用 `GET /flow/controller-service-types` 找到 `JsonTreeReader`，建立並啟用
   `RecordReaderFactory` Controller Service。
5. 設定明確的 Avro schema，讓缺少欄位的 JSON 先轉成 nullable Record，再交給自訂
   Processor 執行商業規則驗證。
6. 建立三個 `GenerateFlowFile` 測試來源、自訂 Processor 與兩個 `LogAttribute`。
7. 以 REST API 建立三條輸入連線，以及 `success`、`failure` 兩條分流連線。
8. 逐筆使用 `RUN_ONCE` 執行，從 Queue 與 FlowFile API 驗證 status、reason 與原始
   content。

三個案例預期結果：

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

## Processor API 對照

| 課程概念 | 範例位置或責任 |
| --- | --- |
| `AbstractProcessor` | `ValidateOrderJsonProcessor` 的基底類別 |
| `PropertyDescriptor` | `Record Reader`，指定 `RecordReaderFactory` Controller Service |
| `Relationship` | `REL_SUCCESS`、`REL_FAILURE` |
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

完整的課程背景、SPI、JAR、NAR 與 REST API 操作請閱讀：

```text
docs/nifi-training/11-00-custom-processor-spi.md
```
