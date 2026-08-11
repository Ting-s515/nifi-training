# 補充：NiFi REST API Endpoint 清單

目標：讓你知道 NiFi UI 背後幾乎都可以透過 REST API 操作，並提供目前本機 NiFi 2.9.0 的 endpoint 索引，方便後續公司專案用程式串接。

這份是補充文檔，不是實作 Lab。建議在 Lab 01 到 Lab 03 熟悉 UI 操作後閱讀。

## 來源與版本

官方文件已確認 NiFi 提供 REST API，入口文件如下：

- Apache NiFi REST API：https://nifi.apache.org/nifi-docs/rest-api.html
- Apache NiFi Documentation：https://nifi.apache.org/documentation/

本文件的 endpoint 清單來自你目前本機容器中的 NiFi 2.9.0 swagger 檔：

```text
/opt/nifi/nifi-current/work/jetty/nifi-web-api-2.9.0.war/webapp/docs/rest-api/swagger.json
```

本機實測結果：

- NiFi URL：`https://localhost:8443/nifi`
- API base URL：`https://localhost:8443/nifi-api`
- 目前 swagger 解析結果：`265` paths，`352` operations

注意：NiFi REST API 會隨版本變動。公司專案若升級 NiFi，應重新用該版本的 swagger 或官方文件確認 endpoint。

## API 使用基本流程

目前本機 NiFi 使用 HTTPS + Single User Authentication。呼叫 API 前通常先取得 token。

PowerShell 範例：

```powershell
$envMap = Get-Content .\.env | ConvertFrom-StringData

$token = curl.exe -k -s -X POST "https://localhost:8443/nifi-api/access/token" `
  -H "Content-Type: application/x-www-form-urlencoded" `
  --data-urlencode "username=$($envMap.NIFI_USERNAME)" `
  --data-urlencode "password=$($envMap.NIFI_PASSWORD)"
```

取得 token 後呼叫 API：

```powershell
curl.exe -k -H "Authorization: Bearer $token" `
  "https://localhost:8443/nifi-api/flow/current-user"
```

## 常見注意事項

- `GET` 多半是查詢。
- `POST` 多半是建立、送出 request、觸發動作。
- `PUT` 多半是更新設定或狀態。
- `DELETE` 多半是刪除或取消 request。
- 修改 Processor、Connection、Process Group 等元件時，常會需要帶 `revision`，避免多人同時修改造成版本衝突。
- 啟停 Processor 通常用 `PUT /processors/{id}/run-status`。
- 啟停 Controller Service 通常用 `PUT /controller-services/{id}/run-status`。
- 安裝 custom Processor NAR 使用 `/controller/nar-manager/nars/...`，不要把一般 JAR 直接當成 NiFi extension 部署。
- Queue 列表、下載 content、drop request 走 `/flowfile-queues/...`。
- Data Provenance 查詢走 `/provenance` 和 `/provenance-events/...`。
- Production 程式不要把帳密硬編碼在程式碼中，應使用安全的 secret 管理方式。

## 常見 API 對應 UI 操作

| UI 操作 | 常用 API |
| --- | --- |
| 查目前使用者 | `GET /flow/current-user` |
| 查 root flow | `GET /flow/process-groups/root` |
| 建立 Processor | `POST /process-groups/{id}/processors` |
| 更新 Processor | `PUT /processors/{id}` |
| 啟停 Processor | `PUT /processors/{id}/run-status` |
| 建立 Connection | `POST /process-groups/{id}/connections` |
| 查 Connection | `GET /connections/{id}` |
| 建立 Controller Service | `POST /process-groups/{id}/controller-services` |
| 查 Controller Service type | `GET /flow/controller-service-types` |
| 更新 Controller Service | `PUT /controller-services/{id}` |
| 啟停 Controller Service | `PUT /controller-services/{id}/run-status` |
| 查 Queue FlowFile | `POST /flowfile-queues/{id}/listing-requests` |
| 清空 Queue | `POST /flowfile-queues/{id}/drop-requests` |
| 查 Bulletin | `GET /flow/bulletin-board` |
| 查 Provenance | `POST /provenance` |
| 查 Processor status | `GET /flow/processors/{id}/status` |
| 查 Process Group status | `GET /flow/process-groups/{id}/status` |

## Custom Processor SPI API 實作流程

Lab 11 的範例位於 `examples/nifi-custom-processor/`，以 REST API 完成 NAR 安裝與測試 Flow 建立。建議沿著「先確認 extension，再建立 flow，最後讀回結果」的順序，不要只看到 upload 成功就假設 Processor 已可執行。

### 1. 上傳並等待 NAR 安裝

```powershell
$narPath = ".\examples\nifi-custom-processor\nifi-training-custom-processor-nar\target\nifi-training-custom-processor-nar-2.1.0.nar"

curl.exe -k -sS -X POST `
  -H "Authorization: Bearer $token" `
  -H "Content-Type: application/octet-stream" `
  -H "filename: nifi-training-custom-processor-nar-2.1.0.nar" `
  --data-binary "@$narPath" `
  "https://localhost:8443/nifi-api/controller/nar-manager/nars/content"
```

上傳回應中的 NAR identifier 只代表安裝請求已建立。接著輪詢：

```text
GET /controller/nar-manager/nars/{id}
```

等到 `installComplete = true`，若有 `failureMessage` 就先查 NiFi log，不要繼續建立 Processor。

### 2. 驗證 Processor type

```text
GET /flow/processor-types
```

篩選：

```text
com.example.nifi.training.ValidateOrderJsonProcessor
com.example.nifi.training.OrderPolicyProcessor
```

同時讀取 response 的 `bundle.group`、`bundle.artifact` 與 `bundle.version`，再帶入建立 Processor 的 request。這能讓程式使用 NiFi 目前實際註冊的 bundle metadata，而不是依賴 UI 顯示文字或自行猜版本。若要建立政策流程，將 `type` 改為 `OrderPolicyProcessor`，並依 Lab 11 的 properties 與四條 relationship 建立對應 connection。

### 3. 建立 Processor 與 Connection

建立元件時使用公開的 `ProcessorEntity` 與 `ConnectionEntity` 契約：

```text
POST /process-groups/{id}/processors
POST /process-groups/{id}/connections
```

Processor body 的核心欄位：

```json
{
  "revision": {
    "clientId": "client-id",
    "version": 0
  },
  "component": {
    "name": "Validate order JSON",
    "type": "com.example.nifi.training.ValidateOrderJsonProcessor",
    "bundle": {
      "group": "com.example.nifi.training",
      "artifact": "nifi-training-custom-processor-nar",
      "version": "2.1.0"
    },
    "position": {
      "x": 400.0,
      "y": 0.0
    }
  }
}
```

Connection 以 `component.source`、`component.destination` 與 `selectedRelationships` 描述資料流。`success`、`failure` 都要連到下游，或在 Processor 設定中 auto-terminate。

### 4. 執行一次並讀回 FlowFile

```json
{
  "revision": {
    "clientId": "latest-client-id",
    "version": 1
  },
  "state": "RUN_ONCE"
}
```

將這個 body 送到：

```text
PUT /processors/{id}/run-status
```

再用 queue API 取得結果：

```text
POST /flowfile-queues/{connection-id}/listing-requests
GET  /flowfile-queues/{connection-id}/listing-requests/{request-id}
GET  /flowfile-queues/{connection-id}/flowfiles/{flowfile-uuid}
```

listing response 會提供 FlowFile UUID；FlowFile entity 才包含 attributes，content 則由
`GET /flowfile-queues/{id}/flowfiles/{uuid}/content` 取得。Lab 11 會從 entity 驗證
`training.validation.status` 與 `training.validation.reason`，避免把「queue 有資料」
誤認成「custom Processor 已經完成商業驗證」。

### 5. Revision 與穩定介面邊界

- Java Processor 使用 `nifi-api` 的 `AbstractProcessor`、`ProcessSession`、`ProcessContext` 與 `Relationship`。
- JSON 讀取使用 `RecordReaderFactory` contract 與 `JsonTreeReader` Controller Service。
- 單元測試使用 `nifi-mock` 的 `TestRunner` 與 `MockFlowFile`。
- 部署使用 NAR 與 NAR Manager endpoint。
- Flow 操作使用目前 NiFi 版本的 REST API 與本機 Swagger。
- UI DOM、內部 class、產生器的非公開 JSON 欄位不列為課程依賴。

NiFi 升級後，請重新讀取容器內的 `swagger.json`，確認 request schema、enum 與 endpoint 是否仍一致；尤其不要把 `uiOnly` response 欄位當成自動化程式的穩定契約。

## 取得本機完整 Swagger

本機 NiFi 不一定直接對外提供 swagger JSON 下載路徑，但容器內有 swagger 檔。可用以下方式查看：

```powershell
docker exec nifi-service sh -lc "ls -l /opt/nifi/nifi-current/work/jetty/nifi-web-api-2.9.0.war/webapp/docs/rest-api/swagger.json"
```

用 PowerShell 解析目前容器內所有 endpoint：

```powershell
$json = docker exec nifi-service sh -lc "cat /opt/nifi/nifi-current/work/jetty/nifi-web-api-2.9.0.war/webapp/docs/rest-api/swagger.json"
$spec = $json | ConvertFrom-Json

$rows = foreach ($p in $spec.paths.PSObject.Properties) {
  foreach ($m in $p.Value.PSObject.Properties) {
    if ($m.Name -match "^(get|post|put|delete)$") {
      [PSCustomObject]@{
        Tag = if ($m.Value.tags) { ($m.Value.tags | Select-Object -First 1) } else { "Other" }
        Method = $m.Name.ToUpperInvariant()
        Path = $p.Name
        Summary = $m.Value.summary
      }
    }
  }
}

$rows | Sort-Object Tag, Path, Method | Format-Table -AutoSize
```

## Endpoint 總覽

| 分類 | Operations |
| --- | ---: |
| Access | 3 |
| Authentication | 1 |
| Connections | 3 |
| Connectors | 31 |
| Controller | 46 |
| Controller Services | 14 |
| Counters | 3 |
| DataTransfer | 7 |
| Flow | 67 |
| FlowFileQueues | 8 |
| Funnels | 3 |
| InputPorts | 5 |
| Labels | 3 |
| OutputPorts | 5 |
| ParameterContexts | 14 |
| ParameterProviders | 16 |
| Policies | 5 |
| ProcessGroups | 34 |
| Processors | 15 |
| Provenance | 7 |
| ProvenanceEvents | 6 |
| RemoteProcessGroups | 11 |
| ReportingTasks | 12 |
| Resources | 1 |
| SiteToSite | 2 |
| Snippets | 3 |
| SystemDiagnostics | 2 |
| Tenants | 11 |
| Versions | 14 |

## 完整 Endpoint 清單

### Access

| Method | Path |
| --- | --- |
| DELETE | `/access/logout` |
| GET | `/access/logout/complete` |
| POST | `/access/token` |

### Authentication

| Method | Path |
| --- | --- |
| GET | `/authentication/configuration` |

### Connections

| Method | Path |
| --- | --- |
| DELETE | `/connections/{id}` |
| GET | `/connections/{id}` |
| PUT | `/connections/{id}` |

### Connectors

| Method | Path |
| --- | --- |
| POST | `/connectors` |
| GET | `/connectors/{connectorId}/flow/process-groups/{processGroupId}` |
| GET | `/connectors/{connectorId}/flow/process-groups/{processGroupId}/controller-services` |
| DELETE | `/connectors/{id}` |
| GET | `/connectors/{id}` |
| PUT | `/connectors/{id}` |
| POST | `/connectors/{id}/apply-update` |
| GET | `/connectors/{id}/assets` |
| POST | `/connectors/{id}/assets` |
| GET | `/connectors/{id}/assets/{assetId}` |
| GET | `/connectors/{id}/configuration-steps` |
| GET | `/connectors/{id}/configuration-steps/{configurationStepName}` |
| PUT | `/connectors/{id}/configuration-steps/{configurationStepName}` |
| GET | `/connectors/{id}/configuration-steps/{configurationStepName}/property-groups/{propertyGroupName}/properties/{propertyName}/allowable-values` |
| POST | `/connectors/{id}/configuration-steps/{configurationStepName}/verify-config` |
| DELETE | `/connectors/{id}/configuration-steps/{configurationStepName}/verify-config/{requestId}` |
| GET | `/connectors/{id}/configuration-steps/{configurationStepName}/verify-config/{requestId}` |
| GET | `/connectors/{id}/controller-services/{controllerServiceId}/state` |
| POST | `/connectors/{id}/controller-services/{controllerServiceId}/state/clear-requests` |
| DELETE | `/connectors/{id}/drain` |
| POST | `/connectors/{id}/drain` |
| GET | `/connectors/{id}/processors/{processorId}/state` |
| POST | `/connectors/{id}/processors/{processorId}/state/clear-requests` |
| POST | `/connectors/{id}/purge-requests` |
| DELETE | `/connectors/{id}/purge-requests/{purge-request-id}` |
| GET | `/connectors/{id}/purge-requests/{purge-request-id}` |
| PUT | `/connectors/{id}/run-status` |
| GET | `/connectors/{id}/search-results` |
| GET | `/connectors/{id}/secrets` |
| GET | `/connectors/{id}/status` |
| DELETE | `/connectors/{id}/working-configuration` |

### Controller

| Method | Path |
| --- | --- |
| POST | `/controller/bulletin` |
| GET | `/controller/cluster` |
| DELETE | `/controller/cluster/nodes/{id}` |
| GET | `/controller/cluster/nodes/{id}` |
| PUT | `/controller/cluster/nodes/{id}` |
| GET | `/controller/config` |
| PUT | `/controller/config` |
| POST | `/controller/controller-services` |
| GET | `/controller/flow-analysis-rules` |
| POST | `/controller/flow-analysis-rules` |
| DELETE | `/controller/flow-analysis-rules/{id}` |
| GET | `/controller/flow-analysis-rules/{id}` |
| PUT | `/controller/flow-analysis-rules/{id}` |
| POST | `/controller/flow-analysis-rules/{id}/bulletins/clear-requests` |
| POST | `/controller/flow-analysis-rules/{id}/config/analysis` |
| POST | `/controller/flow-analysis-rules/{id}/config/verification-requests` |
| DELETE | `/controller/flow-analysis-rules/{id}/config/verification-requests/{requestId}` |
| GET | `/controller/flow-analysis-rules/{id}/config/verification-requests/{requestId}` |
| GET | `/controller/flow-analysis-rules/{id}/descriptors` |
| PUT | `/controller/flow-analysis-rules/{id}/run-status` |
| GET | `/controller/flow-analysis-rules/{id}/state` |
| POST | `/controller/flow-analysis-rules/{id}/state/clear-requests` |
| DELETE | `/controller/history` |
| GET | `/controller/nar-manager/nars` |
| DELETE | `/controller/nar-manager/nars/{id}` |
| GET | `/controller/nar-manager/nars/{id}` |
| GET | `/controller/nar-manager/nars/{id}/content` |
| GET | `/controller/nar-manager/nars/{id}/details` |
| POST | `/controller/nar-manager/nars/content` |
| POST | `/controller/parameter-providers` |
| POST | `/controller/parameter-providers/{id}/bulletins/clear-requests` |
| GET | `/controller/registry-clients` |
| POST | `/controller/registry-clients` |
| DELETE | `/controller/registry-clients/{id}` |
| GET | `/controller/registry-clients/{id}` |
| PUT | `/controller/registry-clients/{id}` |
| POST | `/controller/registry-clients/{id}/bulletins/clear-requests` |
| POST | `/controller/registry-clients/{id}/config/analysis` |
| POST | `/controller/registry-clients/{id}/config/verification-requests` |
| DELETE | `/controller/registry-clients/{id}/config/verification-requests/{requestId}` |
| GET | `/controller/registry-clients/{id}/config/verification-requests/{requestId}` |
| GET | `/controller/registry-clients/{id}/descriptors` |
| GET | `/controller/registry-types` |
| POST | `/controller/reporting-tasks` |
| POST | `/controller/reporting-tasks/import` |
| GET | `/controller/status/history` |

### Controller Services

| Method | Path |
| --- | --- |
| DELETE | `/controller-services/{id}` |
| GET | `/controller-services/{id}` |
| PUT | `/controller-services/{id}` |
| POST | `/controller-services/{id}/bulletins/clear-requests` |
| POST | `/controller-services/{id}/config/analysis` |
| POST | `/controller-services/{id}/config/verification-requests` |
| DELETE | `/controller-services/{id}/config/verification-requests/{requestId}` |
| GET | `/controller-services/{id}/config/verification-requests/{requestId}` |
| GET | `/controller-services/{id}/descriptors` |
| GET | `/controller-services/{id}/references` |
| PUT | `/controller-services/{id}/references` |
| PUT | `/controller-services/{id}/run-status` |
| GET | `/controller-services/{id}/state` |
| POST | `/controller-services/{id}/state/clear-requests` |

### Counters

| Method | Path |
| --- | --- |
| GET | `/counters` |
| PUT | `/counters` |
| PUT | `/counters/{id}` |

### DataTransfer

| Method | Path |
| --- | --- |
| POST | `/data-transfer/{portType}/{portId}/transactions` |
| DELETE | `/data-transfer/input-ports/{portId}/transactions/{transactionId}` |
| PUT | `/data-transfer/input-ports/{portId}/transactions/{transactionId}` |
| POST | `/data-transfer/input-ports/{portId}/transactions/{transactionId}/flow-files` |
| DELETE | `/data-transfer/output-ports/{portId}/transactions/{transactionId}` |
| PUT | `/data-transfer/output-ports/{portId}/transactions/{transactionId}` |
| GET | `/data-transfer/output-ports/{portId}/transactions/{transactionId}/flow-files` |

### Flow

| Method | Path |
| --- | --- |
| GET | `/flow/about` |
| GET | `/flow/additional-details/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/banners` |
| GET | `/flow/bulletin-board` |
| GET | `/flow/client-id` |
| GET | `/flow/cluster/search-results` |
| GET | `/flow/cluster/summary` |
| GET | `/flow/config` |
| GET | `/flow/connections/{id}/statistics` |
| GET | `/flow/connections/{id}/status` |
| GET | `/flow/connections/{id}/status/history` |
| GET | `/flow/connector-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/connector-types` |
| GET | `/flow/connectors` |
| GET | `/flow/content-viewers` |
| GET | `/flow/controller-service-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/controller-service-types` |
| GET | `/flow/controller/bulletins` |
| GET | `/flow/controller/controller-services` |
| GET | `/flow/current-user` |
| GET | `/flow/flow-analysis-rule-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/flow-analysis-rule-types` |
| GET | `/flow/flow-analysis/results` |
| GET | `/flow/flow-analysis/results/{processGroupId}` |
| GET | `/flow/flow-registry-client-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/history` |
| GET | `/flow/history/{id}` |
| GET | `/flow/history/components/{componentId}` |
| GET | `/flow/input-ports/{id}/status` |
| GET | `/flow/listen-ports` |
| GET | `/flow/metrics/{producer}` |
| GET | `/flow/output-ports/{id}/status` |
| GET | `/flow/parameter-contexts` |
| GET | `/flow/parameter-provider-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/parameter-provider-types` |
| GET | `/flow/parameter-providers` |
| GET | `/flow/prioritizers` |
| GET | `/flow/process-groups/{id}` |
| PUT | `/flow/process-groups/{id}` |
| GET | `/flow/process-groups/{id}/breadcrumbs` |
| POST | `/flow/process-groups/{id}/bulletins/clear-requests` |
| GET | `/flow/process-groups/{id}/controller-services` |
| PUT | `/flow/process-groups/{id}/controller-services` |
| GET | `/flow/process-groups/{id}/status` |
| GET | `/flow/process-groups/{id}/status/history` |
| GET | `/flow/processor-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/processor-types` |
| GET | `/flow/processors/{id}/status` |
| GET | `/flow/processors/{id}/status/history` |
| GET | `/flow/registries` |
| GET | `/flow/registries/{id}/branches` |
| GET | `/flow/registries/{id}/buckets` |
| GET | `/flow/registries/{registry-id}/branches/{branch-id-a}/buckets/{bucket-id-a}/flows/{flow-id-a}/{version-a}/diff/branches/{branch-id-b}/buckets/{bucket-id-b}/flows/{flow-id-b}/{version-b}` |
| GET | `/flow/registries/{registry-id}/buckets/{bucket-id}/flows` |
| GET | `/flow/registries/{registry-id}/buckets/{bucket-id}/flows/{flow-id}/details` |
| GET | `/flow/registries/{registry-id}/buckets/{bucket-id}/flows/{flow-id}/versions` |
| GET | `/flow/remote-process-groups/{id}/status` |
| GET | `/flow/remote-process-groups/{id}/status/history` |
| GET | `/flow/reporting-task-definition/{group}/{artifact}/{version}/{type}` |
| GET | `/flow/reporting-task-types` |
| GET | `/flow/reporting-tasks` |
| GET | `/flow/reporting-tasks/download` |
| GET | `/flow/reporting-tasks/snapshot` |
| GET | `/flow/runtime-manifest` |
| GET | `/flow/search-results` |
| GET | `/flow/status` |
| GET | `/flow/steps/{group}/{artifact}/{version}/{connectorType}/{stepName}` |

### FlowFileQueues

| Method | Path |
| --- | --- |
| POST | `/flowfile-queues/{id}/drop-requests` |
| DELETE | `/flowfile-queues/{id}/drop-requests/{drop-request-id}` |
| GET | `/flowfile-queues/{id}/drop-requests/{drop-request-id}` |
| GET | `/flowfile-queues/{id}/flowfiles/{flowfile-uuid}` |
| GET | `/flowfile-queues/{id}/flowfiles/{flowfile-uuid}/content` |
| POST | `/flowfile-queues/{id}/listing-requests` |
| DELETE | `/flowfile-queues/{id}/listing-requests/{listing-request-id}` |
| GET | `/flowfile-queues/{id}/listing-requests/{listing-request-id}` |

### Funnels

| Method | Path |
| --- | --- |
| DELETE | `/funnels/{id}` |
| GET | `/funnels/{id}` |
| PUT | `/funnels/{id}` |

### InputPorts

| Method | Path |
| --- | --- |
| DELETE | `/input-ports/{id}` |
| GET | `/input-ports/{id}` |
| PUT | `/input-ports/{id}` |
| POST | `/input-ports/{id}/bulletins/clear-requests` |
| PUT | `/input-ports/{id}/run-status` |

### Labels

| Method | Path |
| --- | --- |
| DELETE | `/labels/{id}` |
| GET | `/labels/{id}` |
| PUT | `/labels/{id}` |

### OutputPorts

| Method | Path |
| --- | --- |
| DELETE | `/output-ports/{id}` |
| GET | `/output-ports/{id}` |
| PUT | `/output-ports/{id}` |
| POST | `/output-ports/{id}/bulletins/clear-requests` |
| PUT | `/output-ports/{id}/run-status` |

### ParameterContexts

| Method | Path |
| --- | --- |
| POST | `/parameter-contexts` |
| GET | `/parameter-contexts/{contextId}/assets` |
| POST | `/parameter-contexts/{contextId}/assets` |
| DELETE | `/parameter-contexts/{contextId}/assets/{assetId}` |
| GET | `/parameter-contexts/{contextId}/assets/{assetId}` |
| POST | `/parameter-contexts/{contextId}/update-requests` |
| DELETE | `/parameter-contexts/{contextId}/update-requests/{requestId}` |
| GET | `/parameter-contexts/{contextId}/update-requests/{requestId}` |
| POST | `/parameter-contexts/{contextId}/validation-requests` |
| DELETE | `/parameter-contexts/{contextId}/validation-requests/{id}` |
| GET | `/parameter-contexts/{contextId}/validation-requests/{id}` |
| DELETE | `/parameter-contexts/{id}` |
| GET | `/parameter-contexts/{id}` |
| PUT | `/parameter-contexts/{id}` |

### ParameterProviders

| Method | Path |
| --- | --- |
| DELETE | `/parameter-providers/{id}` |
| GET | `/parameter-providers/{id}` |
| PUT | `/parameter-providers/{id}` |
| POST | `/parameter-providers/{id}/bulletins/clear-requests` |
| POST | `/parameter-providers/{id}/config/analysis` |
| POST | `/parameter-providers/{id}/config/verification-requests` |
| DELETE | `/parameter-providers/{id}/config/verification-requests/{requestId}` |
| GET | `/parameter-providers/{id}/config/verification-requests/{requestId}` |
| GET | `/parameter-providers/{id}/descriptors` |
| POST | `/parameter-providers/{id}/parameters/fetch-requests` |
| GET | `/parameter-providers/{id}/references` |
| GET | `/parameter-providers/{id}/state` |
| POST | `/parameter-providers/{id}/state/clear-requests` |
| POST | `/parameter-providers/{providerId}/apply-parameters-requests` |
| DELETE | `/parameter-providers/{providerId}/apply-parameters-requests/{requestId}` |
| GET | `/parameter-providers/{providerId}/apply-parameters-requests/{requestId}` |

### Policies

| Method | Path |
| --- | --- |
| POST | `/policies` |
| GET | `/policies/{action}/{resource}` |
| DELETE | `/policies/{id}` |
| GET | `/policies/{id}` |
| PUT | `/policies/{id}` |

### ProcessGroups

| Method | Path |
| --- | --- |
| DELETE | `/process-groups/{id}` |
| GET | `/process-groups/{id}` |
| PUT | `/process-groups/{id}` |
| GET | `/process-groups/{id}/connections` |
| POST | `/process-groups/{id}/connections` |
| POST | `/process-groups/{id}/controller-services` |
| POST | `/process-groups/{id}/copy` |
| GET | `/process-groups/{id}/download` |
| POST | `/process-groups/{id}/empty-all-connections-requests` |
| DELETE | `/process-groups/{id}/empty-all-connections-requests/{drop-request-id}` |
| GET | `/process-groups/{id}/empty-all-connections-requests/{drop-request-id}` |
| PUT | `/process-groups/{id}/flow-contents` |
| GET | `/process-groups/{id}/funnels` |
| POST | `/process-groups/{id}/funnels` |
| GET | `/process-groups/{id}/input-ports` |
| POST | `/process-groups/{id}/input-ports` |
| GET | `/process-groups/{id}/labels` |
| POST | `/process-groups/{id}/labels` |
| GET | `/process-groups/{id}/local-modifications` |
| GET | `/process-groups/{id}/output-ports` |
| POST | `/process-groups/{id}/output-ports` |
| PUT | `/process-groups/{id}/paste` |
| GET | `/process-groups/{id}/process-groups` |
| POST | `/process-groups/{id}/process-groups` |
| POST | `/process-groups/{id}/process-groups/import` |
| POST | `/process-groups/{id}/process-groups/upload` |
| GET | `/process-groups/{id}/processors` |
| POST | `/process-groups/{id}/processors` |
| GET | `/process-groups/{id}/remote-process-groups` |
| POST | `/process-groups/{id}/remote-process-groups` |
| POST | `/process-groups/{id}/replace-requests` |
| POST | `/process-groups/{id}/snippet-instance` |
| DELETE | `/process-groups/replace-requests/{id}` |
| GET | `/process-groups/replace-requests/{id}` |

### Processors

| Method | Path |
| --- | --- |
| DELETE | `/processors/{id}` |
| GET | `/processors/{id}` |
| PUT | `/processors/{id}` |
| POST | `/processors/{id}/bulletins/clear-requests` |
| POST | `/processors/{id}/config/analysis` |
| POST | `/processors/{id}/config/verification-requests` |
| DELETE | `/processors/{id}/config/verification-requests/{requestId}` |
| GET | `/processors/{id}/config/verification-requests/{requestId}` |
| GET | `/processors/{id}/descriptors` |
| GET | `/processors/{id}/diagnostics` |
| PUT | `/processors/{id}/run-status` |
| GET | `/processors/{id}/state` |
| POST | `/processors/{id}/state/clear-requests` |
| DELETE | `/processors/{id}/threads` |
| POST | `/processors/run-status-details/queries` |

### Provenance

| Method | Path |
| --- | --- |
| POST | `/provenance` |
| DELETE | `/provenance/{id}` |
| GET | `/provenance/{id}` |
| POST | `/provenance/lineage` |
| DELETE | `/provenance/lineage/{id}` |
| GET | `/provenance/lineage/{id}` |
| GET | `/provenance/search-options` |

### ProvenanceEvents

| Method | Path |
| --- | --- |
| GET | `/provenance-events/{id}` |
| GET | `/provenance-events/{id}/content/input` |
| GET | `/provenance-events/{id}/content/output` |
| GET | `/provenance-events/latest/{componentId}` |
| POST | `/provenance-events/latest/replays` |
| POST | `/provenance-events/replays` |

### RemoteProcessGroups

| Method | Path |
| --- | --- |
| DELETE | `/remote-process-groups/{id}` |
| GET | `/remote-process-groups/{id}` |
| PUT | `/remote-process-groups/{id}` |
| POST | `/remote-process-groups/{id}/bulletins/clear-requests` |
| PUT | `/remote-process-groups/{id}/input-ports/{port-id}` |
| PUT | `/remote-process-groups/{id}/input-ports/{port-id}/run-status` |
| PUT | `/remote-process-groups/{id}/output-ports/{port-id}` |
| PUT | `/remote-process-groups/{id}/output-ports/{port-id}/run-status` |
| PUT | `/remote-process-groups/{id}/run-status` |
| GET | `/remote-process-groups/{id}/state` |
| PUT | `/remote-process-groups/process-group/{id}/run-status` |

### ReportingTasks

| Method | Path |
| --- | --- |
| DELETE | `/reporting-tasks/{id}` |
| GET | `/reporting-tasks/{id}` |
| PUT | `/reporting-tasks/{id}` |
| POST | `/reporting-tasks/{id}/bulletins/clear-requests` |
| POST | `/reporting-tasks/{id}/config/analysis` |
| POST | `/reporting-tasks/{id}/config/verification-requests` |
| DELETE | `/reporting-tasks/{id}/config/verification-requests/{requestId}` |
| GET | `/reporting-tasks/{id}/config/verification-requests/{requestId}` |
| GET | `/reporting-tasks/{id}/descriptors` |
| PUT | `/reporting-tasks/{id}/run-status` |
| GET | `/reporting-tasks/{id}/state` |
| POST | `/reporting-tasks/{id}/state/clear-requests` |

### Resources

| Method | Path |
| --- | --- |
| GET | `/resources` |

### SiteToSite

| Method | Path |
| --- | --- |
| GET | `/site-to-site` |
| GET | `/site-to-site/peers` |

### Snippets

| Method | Path |
| --- | --- |
| POST | `/snippets` |
| DELETE | `/snippets/{id}` |
| PUT | `/snippets/{id}` |

### SystemDiagnostics

| Method | Path |
| --- | --- |
| GET | `/system-diagnostics` |
| GET | `/system-diagnostics/jmx-metrics` |

### Tenants

| Method | Path |
| --- | --- |
| GET | `/tenants/search-results` |
| GET | `/tenants/user-groups` |
| POST | `/tenants/user-groups` |
| DELETE | `/tenants/user-groups/{id}` |
| GET | `/tenants/user-groups/{id}` |
| PUT | `/tenants/user-groups/{id}` |
| GET | `/tenants/users` |
| POST | `/tenants/users` |
| DELETE | `/tenants/users/{id}` |
| GET | `/tenants/users/{id}` |
| PUT | `/tenants/users/{id}` |

### Versions

| Method | Path |
| --- | --- |
| POST | `/versions/active-requests` |
| DELETE | `/versions/active-requests/{id}` |
| PUT | `/versions/active-requests/{id}` |
| DELETE | `/versions/process-groups/{id}` |
| GET | `/versions/process-groups/{id}` |
| POST | `/versions/process-groups/{id}` |
| PUT | `/versions/process-groups/{id}` |
| GET | `/versions/process-groups/{id}/download` |
| DELETE | `/versions/revert-requests/{id}` |
| GET | `/versions/revert-requests/{id}` |
| POST | `/versions/revert-requests/process-groups/{id}` |
| DELETE | `/versions/update-requests/{id}` |
| GET | `/versions/update-requests/{id}` |
| POST | `/versions/update-requests/process-groups/{id}` |

## 後續實作建議

如果公司專案要用程式自動操作 NiFi，建議先從小範圍開始：

1. 取得 token。
2. `GET /flow/current-user` 確認授權正常。
3. `GET /flow/process-groups/root` 確認能讀 flow。
4. `GET /process-groups/{id}/processors` 找 Processor。
5. `PUT /processors/{id}/run-status` 練習啟停。
6. `GET /flow/processor-types` 確認 custom NAR 已註冊。
7. 再逐步進到建立 Processor、建立 Connection、更新 Controller Service。

不要一開始就直接寫大量自動化建立整張 flow。NiFi API 需要處理 revision、validation、Controller Service 狀態、relationship、position、component id 等細節，適合從查詢與啟停開始練。
