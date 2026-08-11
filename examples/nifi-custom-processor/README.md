# NiFi Custom Processor SPI 範例

這個範例使用 NiFi 2.9.0 的公開 Java API，建立一個可部署的 Processor Bundle：

`GenerateFlowFile → ContentDigestProcessor → LogAttribute`

`ContentDigestProcessor` 讀取 FlowFile content，使用 SHA-256 或 SHA-512 計算摘要，
將小寫十六進位結果寫入 FlowFile attribute，並保留原始 content。成功與失敗都使用
明確的 Relationship；這讓課程可以同時練習 Processor API、NAR 打包、單元測試與 REST
API 部署。

## 目錄

- `nifi-training-custom-processor-processors/`：Processor Java 原始碼、ServiceLoader
  descriptor 與 `nifi-mock` 測試。
- `nifi-training-custom-processor-nar/`：將 Processor JAR 打包成 NiFi 可載入的 NAR。
- `scripts/setup-flow.ps1`：以 NiFi REST API 上傳 NAR、建立測試 Process Group 與執行
  一次的 flow。
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

成功後的 NAR：

```text
examples/nifi-custom-processor/nifi-training-custom-processor-nar/target/nifi-training-custom-processor-nar-1.0.0.nar
```

這個範例要求 Java 21 的編譯目標，實際 Maven 執行放在 Docker 的 Maven + JDK 21
映像中；第一次執行會下載映像與 Maven 相依套件。

## 透過 REST API 建立測試 Flow

先確認根目錄 `.env` 已有本機 NiFi 帳密，並且 NiFi 已啟動：

```powershell
docker compose up -d
```

完成建置後執行：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1
```

腳本會依序：

1. 取得 `POST /access/token` 的 Bearer token。
2. 以 `POST /controller/nar-manager/nars/content` 上傳 NAR。
3. 輪詢 NAR 安裝狀態，並用 `GET /flow/processor-types` 驗證 Processor 已註冊。
4. 建立獨立 Process Group、`GenerateFlowFile`、自訂 Processor 與兩個
   `LogAttribute`。
5. 以 `POST /process-groups/{id}/connections` 建立 success/failure 連線。
6. 使用 `PUT /processors/{id}/run-status` 的 `RUN_ONCE` 觸發來源與自訂 Processor。
7. 用 Queue listing 與 FlowFile API 讀回 `content.digest` attribute。

預設不會刪除建立的 Process Group，方便回到 UI 觀察 queue、Processor 設定與 bulletin。
若要重跑且 NAR 已經安裝，可略過上傳：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1 -SkipNarUpload
```

`-Cleanup` 只適合練習完成後使用；它會嘗試停止本次建立的元件並刪除 Process Group：

```powershell
.\examples\nifi-custom-processor\scripts\setup-flow.ps1 -Cleanup
```

## Processor API 對照

| 課程概念 | 範例位置 |
| --- | --- |
| `AbstractProcessor` | `ContentDigestProcessor` 的基底類別 |
| Property descriptor | `HASH_ALGORITHM`、`OUTPUT_ATTRIBUTE` |
| Relationship | `REL_SUCCESS`、`REL_FAILURE` |
| 讀取 FlowFile content | `ProcessSession.read` |
| 寫入 attribute | `ProcessSession.putAttribute` |
| 成功/失敗路由 | `ProcessSession.transfer` |
| ServiceLoader 註冊 | `META-INF/services/org.apache.nifi.processor.Processor` |
| 單元測試 | `TestRunners.newTestRunner`、`MockFlowFile` |
| 可部署封裝 | `nifi-training-custom-processor-nar` |

課程只依賴 `nifi-api`、`nifi-mock` 與 NAR Maven plugin 所需的公開契約；不依賴 UI
內部 class、瀏覽器操作或 Python script，方便將 Processor 邏輯搬到公司專案後繼續維護。
