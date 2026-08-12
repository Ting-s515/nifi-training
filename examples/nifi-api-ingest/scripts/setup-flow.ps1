[CmdletBinding()]
param(
    [string]$BaseUrl = "https://localhost:8443/nifi-api",
    [string]$GroupName = "training-lab-12-api-ingest",
    [Parameter(Mandatory = $true)]
    [string]$KeycloakTokenUri,
    [string]$KeycloakClientId = "spring-course-demo",
    [Parameter(Mandatory = $true)]
    [string]$KeycloakClientSecret,
    [string]$GatewayUrl = "http://host.docker.internal:9080/gateway/products-ingest",
    [switch]$ReplaceExisting,
    [switch]$RunOnce,
    [switch]$VerifyReplay,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\..\nifi-custom-processor\scripts\nifi-flow-helper.ps1")

if ([string]::IsNullOrWhiteSpace($KeycloakTokenUri)) {
    throw "請提供 Keycloak Token URI。"
}
if ([string]::IsNullOrWhiteSpace($KeycloakClientSecret)) {
    throw "請提供 Keycloak Client Secret；不要把 Secret 寫進腳本或文件。"
}
if ([string]::IsNullOrWhiteSpace($GatewayUrl)) {
    throw "請提供 APISIX Gateway URL。"
}
if ($VerifyReplay) {
    $RunOnce = $true
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..")).Path
$envPath = Join-Path $repositoryRoot ".env"
$context = New-NifiContext -BaseUrl $BaseUrl
$nifiVersion = "2.9.0"
$parameterContextName = "$GroupName-parameters"
$parameterContextDescription = "Lab 12 API ingest 的環境參數；Secret 只由執行時注入。"
$workerProcessorIds = [System.Collections.Generic.List[string]]::new()
$terminalConnectionIds = [System.Collections.Generic.List[string]]::new()
$parameterContextWasCreated = $false

$mockRecords = @(
    [PSCustomObject]@{
        sourceRecordId = "mock-1001"
        name = "USB-C 擴充座"
        description = "NiFi 模擬外部資料來源的第一筆商品"
        price = 1890
        initialStock = 8
    }
    [PSCustomObject]@{
        sourceRecordId = "mock-1002"
        name = "無線鍵盤"
        description = "NiFi 模擬外部資料來源的第二筆商品"
        price = 1290
        initialStock = 12
    }
    [PSCustomObject]@{
        sourceRecordId = "mock-1003"
        name = "錯誤價格商品"
        description = "price 為負數，應由 Spring API 驗證拒絕"
        price = -1
        initialStock = 1
    }
)
$mockPayload = $mockRecords | ConvertTo-Json -Depth 5 -Compress

function Set-ProcessorRunState {
    param(
        [object]$Context,
        [string]$ProcessorId,
        [ValidateSet("RUNNING", "STOPPED")]
        [string]$State
    )

    $current = Get-ProcessorEntity -Context $Context -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        state = $State
    }
    Invoke-NifiJson -Context $Context -Method "PUT" `
        -Path "/processors/$ProcessorId/run-status" -Body $body | Out-Null
}

function Start-ApiIngestWorkers {
    foreach ($processorId in $workerProcessorIds) {
        Set-ProcessorRunState -Context $context -ProcessorId $processorId -State "RUNNING"
    }

    # 下游必須先開始消費，RUN_ONCE 才能讓同一批 mock records 穿過整條 flow。
    Start-Sleep -Seconds 2
}

function Stop-ApiIngestWorkers {
    foreach ($processorId in $workerProcessorIds) {
        try {
            Stop-Processor -Context $context -ProcessorId $processorId
            Wait-ProcessorStopped -Context $context -ProcessorId $processorId
        } catch {
            Write-Warning "停止 Processor $processorId 失敗：$($_.Exception.Message)"
        }
    }
}

function Clear-TerminalQueues {
    $flowEntity = Get-NifiProcessGroupFlow -Context $context -GroupId $context.CreatedGroupId
    foreach ($connectionId in $terminalConnectionIds) {
        $connection = @($flowEntity.processGroupFlow.flow.connections | Where-Object {
                $_.component.id -eq $connectionId
            } | Select-Object -First 1)
        if ($connection.Count -gt 0 -and $connection[0].status.aggregateSnapshot.flowFilesQueued -gt 0) {
            Drop-QueueFlowFiles -Context $context -ConnectionId $connectionId
        }
    }
}

function Get-ResultFlowFile {
    param(
        [string]$ConnectionId,
        [object]$Summary
    )

    return Get-FlowFileEntity -Context $context `
        -ConnectionId $ConnectionId -FlowFileId $Summary.uuid
}

function Assert-SuccessResponses {
    param(
        [object[]]$Summaries,
        [string[]]$ExpectedStatusCodes,
        [Nullable[bool]]$ExpectedDuplicate
    )

    if ($Summaries.Count -ne 2) {
        throw "成功分支預期兩筆 FlowFile，實際取得 $($Summaries.Count) 筆。"
    }

    foreach ($summary in $Summaries) {
        $flowFile = Get-ResultFlowFile -ConnectionId $successConnection.id -Summary $summary
        $attributes = $flowFile.flowFile.attributes
        if ($attributes.'invokehttp.status.code' -notin $ExpectedStatusCodes) {
            throw "成功分支 HTTP status 不符：$($attributes.'invokehttp.status.code')"
        }

        $response = (Get-FlowFileContent -Context $context `
                -ConnectionId $successConnection.id -FlowFileId $summary.uuid) | ConvertFrom-Json
        $duplicate = [bool]$response.data.duplicate
        if ($null -ne $ExpectedDuplicate -and $duplicate -ne $ExpectedDuplicate) {
            throw "sourceRecordId $($response.data.sourceRecordId) 的 duplicate 結果不符。"
        }
        if ($attributes.'invokehttp.status.code' -eq "201" -and $duplicate) {
            throw "HTTP 201 不應標記 duplicate=true。"
        }
        if ($attributes.'invokehttp.status.code' -eq "200" -and -not $duplicate) {
            throw "HTTP 200 重送結果應標記 duplicate=true。"
        }
    }
}

function Assert-BusinessFailures {
    param([object[]]$Summaries)

    if ($Summaries.Count -ne 1) {
        throw "業務驗證失敗分支預期一筆 FlowFile，實際取得 $($Summaries.Count) 筆。"
    }

    $flowFile = Get-ResultFlowFile -ConnectionId $businessFailureConnection.id -Summary $Summaries[0]
    $attributes = $flowFile.flowFile.attributes
    if ($attributes.'invokehttp.status.code' -ne "400") {
        throw "業務驗證失敗預期 HTTP 400，實際取得 $($attributes.'invokehttp.status.code')。"
    }
}

function Invoke-ApiIngestOnce {
    param(
        [string]$RunLabel,
        [string[]]$ExpectedSuccessStatusCodes,
        [Nullable[bool]]$ExpectedDuplicate
    )

    Start-ApiIngestWorkers
    try {
        Invoke-ProcessorOnce -Context $context -ProcessorId $source.id
        $successSummaries = @(Wait-QueueHasFlowFile -Context $context `
                -ConnectionId $successConnection.id -MinimumCount 2 -TimeoutSeconds 120)
        $businessSummaries = @(Wait-QueueHasFlowFile -Context $context `
                -ConnectionId $businessFailureConnection.id -MinimumCount 1 -TimeoutSeconds 120)
        Assert-SuccessResponses -Summaries $successSummaries `
            -ExpectedStatusCodes $ExpectedSuccessStatusCodes -ExpectedDuplicate $ExpectedDuplicate
        Assert-BusinessFailures -Summaries $businessSummaries
        Write-Host "$RunLabel 驗證成功：2 筆商品進入 success，1 筆無效資料進入 business validation failure。"
    } finally {
        Stop-ApiIngestWorkers
        Clear-TerminalQueues
    }
}

try {
    Set-NifiAccessToken -Context $context -EnvPath $envPath
    Write-Host "已取得 NiFi access token。"

    $root = Invoke-NifiJson -Context $context -Method "GET" -Path "/flow/process-groups/root"
    $rootGroupId = $root.processGroupFlow.id
    if ([string]::IsNullOrWhiteSpace($rootGroupId)) {
        throw "無法從 root flow response 取得 Process Group id。"
    }

    $existingGroups = @(Get-NifiChildProcessGroups -Context $context `
            -ParentGroupId $rootGroupId -GroupName $GroupName)
    if ($existingGroups.Count -gt 0) {
        if (-not $ReplaceExisting) {
            throw "已存在 Process Group '$GroupName'；若要由腳本替換請加入 -ReplaceExisting。"
        }
        if ($existingGroups.Count -gt 1) {
            $groupIds = @($existingGroups | ForEach-Object { $_.id }) -join ", "
            throw "找到多個同名 Process Group '$GroupName'：$groupIds。"
        }
        Remove-NifiProcessGroup -Context $context -GroupId $existingGroups[0].id
    }

    $groupBody = @{
        revision = New-Revision -Context $context
        component = @{
            name = $GroupName
            position = @{ x = 0.0; y = 0.0 }
        }
    }
    $groupEntity = Invoke-NifiJson -Context $context -Method "POST" `
        -Path "/process-groups/$rootGroupId/process-groups" -Body $groupBody
    $context.CreatedGroupId = $groupEntity.id
    Write-Host "已建立 Process Group：$GroupName ($($context.CreatedGroupId))"

    $parameterDefinitions = @(
        [PSCustomObject]@{
            Name = "keycloak.token-uri"
            Description = "OAuth2 Client Credentials Token Endpoint"
            Sensitive = $false
            Value = $KeycloakTokenUri
        }
        [PSCustomObject]@{
            Name = "keycloak.client-id"
            Description = "提供 NiFi ingest 權限的 Keycloak Client ID"
            Sensitive = $false
            Value = $KeycloakClientId
        }
        [PSCustomObject]@{
            Name = "keycloak.client-secret"
            Description = "只在執行時注入的 Keycloak Client Secret"
            Sensitive = $true
            Value = $KeycloakClientSecret
        }
        [PSCustomObject]@{
            Name = "apisix.gateway-url"
            Description = "NiFi container 可連線的 APISIX Data Plane URL"
            Sensitive = $false
            Value = $GatewayUrl
        }
    )

    $parameterMatches = @(Get-NifiParameterContextByName -Context $context -Name $parameterContextName)
    if ($parameterMatches.Count -gt 1) {
        throw "找到多個同名 Parameter Context '$parameterContextName'。"
    }
    if ($parameterMatches.Count -eq 1) {
        $parameterContext = Get-NifiParameterContextEntity -Context $context `
            -ParameterContextId $parameterMatches[0].id
        $boundGroups = @($parameterContext.component.boundProcessGroups)
        if ($boundGroups.Count -gt 0) {
            throw "Parameter Context '$parameterContextName' 仍被其他 Process Group 綁定，請先人工確認。"
        }
        Set-NifiParameterContext -Context $context `
            -ParameterContextId $parameterContext.id `
            -Name $parameterContextName `
            -Description $parameterContextDescription `
            -Parameters $parameterDefinitions | Out-Null
    } else {
        $parameterContext = New-NifiParameterContext -Context $context `
            -Name $parameterContextName `
            -Description $parameterContextDescription `
            -Parameters $parameterDefinitions
        $parameterContextWasCreated = $true
    }
    Set-NifiProcessGroupParameterContext -Context $context `
        -ProcessGroupId $context.CreatedGroupId -ParameterContextId $parameterContext.id | Out-Null
    Write-Host "已建立並綁定 Parameter Context；Secret 未輸出。"

    $generateType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.standard.GenerateFlowFile" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-standard-nar" -BundleVersion $nifiVersion
    $splitType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.standard.SplitJson" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-standard-nar" -BundleVersion $nifiVersion
    $updateType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.attributes.UpdateAttribute" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-update-attribute-nar" -BundleVersion $nifiVersion
    $invokeType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.standard.InvokeHTTP" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-standard-nar" -BundleVersion $nifiVersion
    $routeType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.standard.RouteOnAttribute" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-standard-nar" -BundleVersion $nifiVersion
    $retryType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.standard.RetryFlowFile" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-standard-nar" -BundleVersion $nifiVersion
    $logType = Get-ProcessorType -Context $context `
        -Type "org.apache.nifi.processors.standard.LogAttribute" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-standard-nar" -BundleVersion $nifiVersion
    $oauthType = Get-ControllerServiceType -Context $context `
        -Type "org.apache.nifi.oauth2.StandardOauth2AccessTokenProvider" `
        -BundleGroup "org.apache.nifi" -BundleArtifact "nifi-oauth2-provider-nar" -BundleVersion $nifiVersion

    $oauthService = New-ControllerService -Context $context `
        -ParentGroupId $context.CreatedGroupId -Name "Keycloak client credentials" `
        -Type $oauthType.type -Bundle $oauthType.bundle
    Set-ControllerServiceProperties -Context $context -ControllerServiceId $oauthService.id -Properties @{
        "Authorization Server URL" = "#{keycloak.token-uri}"
        "Client Authentication Strategy" = "BASIC_AUTHENTICATION"
        "Grant Type" = "client_credentials"
        "Client ID" = "#{keycloak.client-id}"
        "Client Secret" = "#{keycloak.client-secret}"
        "Refresh Window" = "30 sec"
    } | Out-Null
    Set-ControllerServiceState -Context $context -ControllerServiceId $oauthService.id -State "ENABLED"
    Wait-ControllerServiceState -Context $context -ControllerServiceId $oauthService.id -ExpectedState "ENABLED"
    Write-Host "已建立並啟用 OAuth2 Client Credentials Controller Service。"

    $source = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Mock external product records" -Type $generateType.type -Bundle $generateType.bundle `
        -PositionX 0 -PositionY 0
    Set-ProcessorProperties -Context $context -ProcessorId $source.id -Properties @{
        "Data Format" = "Text"
        "Custom Text" = $mockPayload
        "Mime Type" = "application/json"
    } | Out-Null

    $split = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Split product records" -Type $splitType.type -Bundle $splitType.bundle `
        -PositionX 300 -PositionY 0
    Set-ProcessorProperties -Context $context -ProcessorId $split.id -Properties @{
        "JsonPath Expression" = '$.*'
    } | Out-Null
    Set-AutoTerminate -Context $context -ProcessorId $split.id -Relationships @("original", "failure")

    $update = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Mark ingest source" -Type $updateType.type -Bundle $updateType.bundle `
        -PositionX 600 -PositionY 0
    Set-ProcessorProperties -Context $context -ProcessorId $update.id -Properties @{
        "mime.type" = "application/json"
        "training.source" = "mock-external-record"
    } | Out-Null

    $invoke = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "POST through APISIX" -Type $invokeType.type -Bundle $invokeType.bundle `
        -PositionX 900 -PositionY 0
    Set-ProcessorProperties -Context $context -ProcessorId $invoke.id -Properties @{
        "HTTP Method" = "POST"
        "HTTP URL" = "#{apisix.gateway-url}"
        "Request OAuth2 Access Token Provider" = $oauthService.id
        "OAuth2 Access Token Refresh Strategy" = "ON_TOKEN_EXPIRATION"
        "Request Body Enabled" = "true"
        "Request Failure Penalization Enabled" = "false"
        "Request Content-Type" = "application/json"
        "Response Body Attribute Name" = "api.response.body"
        "Response Generation Required" = "true"
    } | Out-Null
    Set-AutoTerminate -Context $context -ProcessorId $invoke.id -Relationships @("Original")

    $route = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Classify HTTP validation result" -Type $routeType.type -Bundle $routeType.bundle `
        -PositionX 1200 -PositionY 300
    Set-ProcessorProperties -Context $context -ProcessorId $route.id -Properties @{
        "business.validation.400" = "`${invokehttp.status.code:equals('400')}"
        "business.validation.409" = "`${invokehttp.status.code:equals('409')}"
        "auth.401" = "`${invokehttp.status.code:equals('401')}"
        "auth.403" = "`${invokehttp.status.code:equals('403')}"
    } | Out-Null

    $retry = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Retry transient API failures" -Type $retryType.type -Bundle $retryType.bundle `
        -PositionX 1200 -PositionY -300
    Set-ProcessorProperties -Context $context -ProcessorId $retry.id -Properties @{
        "Maximum Retries" = "3"
        "Penalize Retries" = "true"
        "Reuse Mode" = "fail"
    } | Out-Null

    $successLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Log successful ingest" -Type $logType.type -Bundle $logType.bundle `
        -PositionX 1500 -PositionY 0
    $businessFailureLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Log business validation failure" -Type $logType.type -Bundle $logType.bundle `
        -PositionX 1500 -PositionY 300
    $authFailureLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Log authentication failure" -Type $logType.type -Bundle $logType.bundle `
        -PositionX 1500 -PositionY 500
    $clientFailureLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Log other client failure" -Type $logType.type -Bundle $logType.bundle `
        -PositionX 1500 -PositionY 700
    $retryExhaustedLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Log retry exhausted" -Type $logType.type -Bundle $logType.bundle `
        -PositionX 1500 -PositionY -300
    $retryFailureLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "Log retry failure" -Type $logType.type -Bundle $logType.bundle `
        -PositionX 1500 -PositionY -500
    foreach ($logProcessor in @($successLog, $businessFailureLog, $authFailureLog, $clientFailureLog, $retryExhaustedLog, $retryFailureLog)) {
        Set-ProcessorProperties -Context $context -ProcessorId $logProcessor.id -Properties @{
            "Log Payload" = "false"
            "Attributes to Log" = "invokehttp.status.code,invokehttp.status.message,sourceRecordId,training.source"
        } | Out-Null
        Set-AutoTerminate -Context $context -ProcessorId $logProcessor.id -Relationships @("success")
    }

    $sourceSplitConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "mock records to split" -SourceId $source.id -DestinationId $split.id -Relationships @("success")
    $splitUpdateConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "split records to attributes" -SourceId $split.id -DestinationId $update.id -Relationships @("split")
    $updateInvokeConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "attributes to HTTP" -SourceId $update.id -DestinationId $invoke.id -Relationships @("success")
    $successConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "HTTP success to LogAttribute" -SourceId $invoke.id -DestinationId $successLog.id -Relationships @("Response")
    $noRetryRouteConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "HTTP 4xx to classifier" -SourceId $invoke.id -DestinationId $route.id -Relationships @("No Retry")
    $retryConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "HTTP retry to RetryFlowFile" -SourceId $invoke.id -DestinationId $retry.id -Relationships @("Retry", "Failure")
    $businessFailureConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "business validation failure" -SourceId $route.id -DestinationId $businessFailureLog.id `
        -Relationships @("business.validation.400", "business.validation.409")
    $authFailureConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "authentication failure" -SourceId $route.id -DestinationId $authFailureLog.id `
        -Relationships @("auth.401", "auth.403")
    $clientFailureConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "other client failure" -SourceId $route.id -DestinationId $clientFailureLog.id `
        -Relationships @("unmatched")
    $retryInvokeConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "retry back to HTTP" -SourceId $retry.id -DestinationId $invoke.id -Relationships @("retry")
    $retryExhaustedConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "retry exhausted" -SourceId $retry.id -DestinationId $retryExhaustedLog.id `
        -Relationships @("retries_exceeded")
    $retryFailureConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId `
        -Name "retry processor failure" -SourceId $retry.id -DestinationId $retryFailureLog.id `
        -Relationships @("failure")

    $terminalConnectionIds.Add($successConnection.id)
    $terminalConnectionIds.Add($businessFailureConnection.id)
    $terminalConnectionIds.Add($authFailureConnection.id)
    $terminalConnectionIds.Add($clientFailureConnection.id)
    $terminalConnectionIds.Add($retryExhaustedConnection.id)
    $terminalConnectionIds.Add($retryFailureConnection.id)
    foreach ($processor in @($split, $update, $invoke, $route, $retry)) {
        $workerProcessorIds.Add($processor.id)
    }

    Write-Host "已建立 GenerateFlowFile、SplitJson、UpdateAttribute、InvokeHTTP、RouteOnAttribute、RetryFlowFile 與 LogAttribute flow。"
    Write-Host "InvokeHTTP 會使用 OAuth2 Controller Service 取得 Bearer token，再呼叫 APISIX Gateway。"

    if ($RunOnce) {
        Invoke-ApiIngestOnce -RunLabel "第一次 mock ingest" `
            -ExpectedSuccessStatusCodes @("201", "200") -ExpectedDuplicate $null
    }
    if ($VerifyReplay) {
        Invoke-ApiIngestOnce -RunLabel "重送同一批資料" `
            -ExpectedSuccessStatusCodes @("200") -ExpectedDuplicate $true
    }

    Write-Host "完成：可在 NiFi UI 開啟 Process Group '$GroupName' 觀察 Parameter Context、OAuth2 Controller Service、HTTP status 分流與 retry cycle。"
} finally {
    Stop-ApiIngestWorkers
    if ($Cleanup -and $context.CreatedGroupId) {
        try {
            Remove-NifiProcessGroup -Context $context -GroupId $context.CreatedGroupId
            if ($parameterContextWasCreated -and $parameterContext.id) {
                Remove-NifiParameterContext -Context $context -ParameterContextId $parameterContext.id
            }
        } catch {
            Write-Warning "Cleanup 失敗，請在 NiFi UI 手動確認 '$GroupName' 與 Parameter Context：$($_.Exception.Message)"
        }
    }
}
