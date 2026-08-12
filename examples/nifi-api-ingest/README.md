# Lab 12 API Ingest 範例

這個範例示範 NiFi 如何以 REST API 建立一條可重現的資料流：

```text
GenerateFlowFile（模擬外部資料）
    -> SplitJson
    -> UpdateAttribute
    -> InvokeHTTP（OAuth2 Client Credentials）
    -> APISIX Gateway
    -> Spring Boot POST /api/v1/integrations/products
```

範例只使用 NiFi 內建 Processor 與公開 Controller Service，不需要重新建置 Lab 11
的 custom Processor NAR。腳本會使用共用的 `nifi-flow-helper.ps1`，透過 NiFi 公開 REST
API 建立 Process Group、Parameter Context、Processor、Controller Service 與 Connection。

## 實作檔案位置

| 檔案 | 在串接中的責任 |
| --- | --- |
| `scripts/setup-flow.ps1` | 定義 mock data、建立 flow、設定 OAuth2 `InvokeHTTP`、連接 APISIX 與驗證 queue |
| `../nifi-custom-processor/scripts/nifi-flow-helper.ps1` | 讀取 NiFi `.env`、取得 NiFi token、封裝 REST API 建立資源 |
| `../../docs/nifi-training/12-nifi-apisix-spring-ingest.md` | 說明 NiFi、APISIX、Spring 的端到端責任與反查方法 |
| `../../../spring-boot-training/spring-course-backend/src/main/java/dev/course/product/integration/apisix/ApisixAdminAdapter.java` | Spring 透過 APISIX Admin API 建立 Upstream、Route 與 path rewrite |
| `../../../spring-boot-training/spring-course-backend/src/main/java/dev/course/product/controller/ProductImportController.java` | 接收 APISIX rewrite 後的商品匯入 request |
| `../../../spring-boot-training/spring-course-backend/src/main/java/dev/course/product/service/ProductImportService.java` | 驗證後的 transaction、冪等與 conflict 業務邏輯 |

請先看 `setup-flow.ps1` 的 Processor 設定，再回到 Spring 的 adapter 與 Controller；
這樣可以看出「NiFi 是呼叫端、APISIX 是 routing boundary、Spring 是 business boundary」，
而不是把三者誤認成同一個 flow engine。

```text
setup-flow.ps1
  ├─ POST /nifi-api/access/token          # 部署 flow 的 NiFi token
  ├─ 建立 InvokeHTTP + OAuth2 Service
  └─ runtime POST /gateway/products-ingest # 執行資料的 Keycloak token
                         │
                         ▼
                   APISIX 9080
                         │ rewrite
                         ▼
        Spring /api/v1/integrations/products
                         │
                         ▼
                  Service → SQLite
```

`setup-flow.ps1` 中的 `#{apisix.gateway-url}` 是 NiFi Parameter Context reference，
`Request OAuth2 Access Token Provider` 則指定 runtime 取得 Keycloak Bearer token 的
Controller Service。這兩個設定就是 NiFi 連到 APISIX 的關鍵接點。

## 執行前提

1. NiFi runtime 已啟動，而且根目錄 `.env` 的 NiFi 帳密可登入。
2. Spring Boot 已用 `local,apisix` profile 啟動。
3. Keycloak `spring-course-demo` Client 已擁有 `nifi-ingest` Role；該 Role 對應
   `POST /api/v1/integrations/products`。
4. Spring 已透過 APISIX Provision API 建立 `products-ingest` endpoint，並將 target path
   設為 `/api/v1/integrations/products`、method 設為 `POST`。
5. `KeycloakTokenUri` 從 NiFi container 可以連線；不要填 `localhost`，因為那會指向
   NiFi container 自己。

Lab 12 的完整前置設定、Keycloak Role、APISIX route 與 Spring API contract，請閱讀
NiFi 課程的 [Lab 12](../../docs/nifi-training/12-nifi-apisix-spring-ingest.md) 與
Spring 課程的 `docs/19-nifi-api-ingest.md`。

## 執行腳本

請從 `nifi-training` repository root 執行。`$targetClientSecret` 應由 Keycloak
Provision response 取得，只存在目前 PowerShell session；不要把 Secret 寫入檔案、
命令歷程或文件：

```powershell
$keycloakTokenUri = 'replace-with-keycloak-token-uri'

.\examples\nifi-api-ingest\scripts\setup-flow.ps1 `
  -KeycloakTokenUri $keycloakTokenUri `
  -KeycloakClientId 'spring-course-demo' `
  -KeycloakClientSecret $targetClientSecret `
  -ReplaceExisting `
  -RunOnce `
  -VerifyReplay
```

腳本會：

- 以 `.env` 的 NiFi 帳密取得 NiFi JWT；後續 REST API 使用 `Authorization: Bearer`。
- 建立或更新 Parameter Context，將 Keycloak Token URI、Client ID、Client Secret 與
  APISIX URL 注入 flow；Secret 以 sensitive parameter 保存，腳本不會輸出它。
- 建立 `GenerateFlowFile`、`SplitJson`、`UpdateAttribute`、`InvokeHTTP`、
  `RouteOnAttribute`、`RetryFlowFile` 與 `LogAttribute`。
- `-RunOnce` 送出兩筆有效商品與一筆負價格商品，預期兩筆進入 success、一筆進入
  business validation failure。
- `-VerifyReplay` 重送相同 `sourceRecordId`，預期有效商品回傳 HTTP 200 且
  `duplicate=true`，驗證匯入 API 的冪等行為。

若只要建立 flow、不呼叫外部服務，可省略 `-RunOnce`；仍需提供一組測試 Secret，因為
OAuth2 Controller Service 需要完整設定：

```powershell
.\examples\nifi-api-ingest\scripts\setup-flow.ps1 `
  -KeycloakTokenUri $keycloakTokenUri `
  -KeycloakClientSecret $targetClientSecret `
  -ReplaceExisting
```

`-ReplaceExisting` 只替換同名的課程 Process Group，不會刪除 Spring SQLite 資料。若要
清除本次建立的 Process Group，並且該次同時新建了 Parameter Context，可加上 `-Cleanup`。

## 分支結果

| NiFi 分支 | 條件 | 用途 |
| --- | --- | --- |
| `Response` → success LogAttribute | Spring 回傳 2xx | 觀察建立或冪等重送結果 |
| `No Retry` → business validation | HTTP 400、409 | 區分欄位驗證與冪等衝突 |
| `No Retry` → authentication | HTTP 401、403 | 檢查 Token、Role 與 Spring Security |
| `No Retry` → other client failure | 其他 4xx | 保留未分類的 client error |
| `Retry`、`Failure` → RetryFlowFile | 5xx 或連線失敗 | 最多重試三次 |
| `retries_exceeded` | 重試仍失敗 | 進入人工排錯或告警流程 |

腳本只驗證 queue 與 status attribute，不會輸出 Bearer token、Client Secret 或完整
response body。
