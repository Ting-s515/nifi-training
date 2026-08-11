function Convert-ToJsonBody {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function New-NifiContext {
    param([string]$BaseUrl)

    return [PSCustomObject]@{
        ApiBaseUrl = $BaseUrl.TrimEnd("/")
        AccessToken = $null
        ClientId = [guid]::NewGuid().ToString()
        CreatedGroupId = $null
        CreatedProcessorIds = [System.Collections.Generic.List[string]]::new()
        CreatedControllerServiceIds = [System.Collections.Generic.List[string]]::new()
    }
}

function Invoke-NifiJson {
    param(
        [object]$Context,
        [ValidateSet("GET", "POST", "PUT", "DELETE")]
        [string]$Method,
        [string]$Path,
        [object]$Body
    )

    $curlArguments = @(
        "-k"
        "-sS"
        "--fail-with-body"
        "-X"
        $Method
        "$($Context.ApiBaseUrl)$Path"
        "-H"
        "Authorization: Bearer $($Context.AccessToken)"
        "-H"
        "Accept: application/json"
    )

    if ($null -ne $Body) {
        $curlArguments += @(
            "-H"
            "Content-Type: application/json"
            "--data-raw"
            (Convert-ToJsonBody -Value $Body)
        )
    }

    $response = & curl.exe @curlArguments 2>&1
    $responseText = ($response -join [Environment]::NewLine).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "NiFi API $Method $Path 失敗：$responseText"
    }

    if ([string]::IsNullOrWhiteSpace($responseText)) {
        return $null
    }

    try {
        return ($responseText | ConvertFrom-Json)
    } catch {
        throw "NiFi API $Method $Path 回傳的內容不是 JSON：$responseText"
    }
}

function Invoke-NifiContent {
    param(
        [object]$Context,
        [string]$Path
    )

    $curlArguments = @(
        "-k"
        "-sS"
        "--fail-with-body"
        "$($Context.ApiBaseUrl)$Path"
        "-H"
        "Authorization: Bearer $($Context.AccessToken)"
    )
    $response = & curl.exe @curlArguments 2>&1
    $responseText = ($response -join [Environment]::NewLine)
    if ($LASTEXITCODE -ne 0) {
        throw "NiFi content API GET $Path 失敗：$responseText"
    }

    return $responseText.Trim()
}

function Set-NifiAccessToken {
    param(
        [object]$Context,
        [string]$EnvPath
    )

    if (-not (Test-Path -LiteralPath $EnvPath)) {
        throw "找不到根目錄 .env：$EnvPath"
    }

    # 透過 .env 在執行時讀取帳密，讓腳本可重用且不把憑證寫進原始碼。
    $envValues = Get-Content -Raw -Encoding UTF8 -LiteralPath $EnvPath | ConvertFrom-StringData
    $username = $envValues.NIFI_USERNAME
    $password = $envValues.NIFI_PASSWORD
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        throw ".env 必須提供 NIFI_USERNAME 與 NIFI_PASSWORD。"
    }

    $tokenArguments = @(
        "-k"
        "-sS"
        "--fail-with-body"
        "-X"
        "POST"
        "$($Context.ApiBaseUrl)/access/token"
        "-H"
        "Content-Type: application/x-www-form-urlencoded"
        "--data-urlencode"
        "username=$username"
        "--data-urlencode"
        "password=$password"
    )
    $Context.AccessToken = ((& curl.exe @tokenArguments 2>&1) -join [Environment]::NewLine).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Context.AccessToken)) {
        throw "無法取得 NiFi access token。"
    }
}

function New-Revision {
    param([object]$Context)

    # 建立資源時先使用本次腳本的 clientId，讓 NiFi 能追蹤這批 REST 變更。
    return @{
        clientId = $Context.ClientId
        version = 0
    }
}

function Get-ProcessorEntity {
    param(
        [object]$Context,
        [string]$ProcessorId
    )

    return Invoke-NifiJson -Context $Context -Method "GET" -Path "/processors/$ProcessorId"
}

function Get-ControllerServiceEntity {
    param(
        [object]$Context,
        [string]$ControllerServiceId
    )

    return Invoke-NifiJson -Context $Context -Method "GET" -Path "/controller-services/$ControllerServiceId"
}

function Invoke-ProcessorOnce {
    param(
        [object]$Context,
        [string]$ProcessorId
    )

    # 先讀取最新 revision，避免以過期版本更新 Processor 而被 NiFi 拒絕。
    $current = Get-ProcessorEntity -Context $Context -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        state = "RUN_ONCE"
    }
    Invoke-NifiJson -Context $Context -Method "PUT" -Path "/processors/$ProcessorId/run-status" -Body $body | Out-Null
}

function Stop-Processor {
    param(
        [object]$Context,
        [string]$ProcessorId
    )

    $current = Get-ProcessorEntity -Context $Context -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        state = "STOPPED"
    }
    Invoke-NifiJson -Context $Context -Method "PUT" -Path "/processors/$ProcessorId/run-status" -Body $body | Out-Null
}

function Set-ProcessorProperties {
    param(
        [object]$Context,
        [string]$ProcessorId,
        [hashtable]$Properties
    )

    $current = Get-ProcessorEntity -Context $Context -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        component = @{
            id = $current.id
            config = @{
                properties = $Properties
            }
        }
    }
    return Invoke-NifiJson -Context $Context -Method "PUT" -Path "/processors/$ProcessorId" -Body $body
}

function Set-AutoTerminate {
    param(
        [object]$Context,
        [string]$ProcessorId,
        [string[]]$Relationships
    )

    $current = Get-ProcessorEntity -Context $Context -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        component = @{
            id = $current.id
            config = @{
                autoTerminatedRelationships = $Relationships
            }
        }
    }
    Invoke-NifiJson -Context $Context -Method "PUT" -Path "/processors/$ProcessorId" -Body $body | Out-Null
}

function Set-ControllerServiceProperties {
    param(
        [object]$Context,
        [string]$ControllerServiceId,
        [hashtable]$Properties
    )

    $current = Get-ControllerServiceEntity -Context $Context -ControllerServiceId $ControllerServiceId
    $body = @{
        revision = $current.revision
        component = @{
            id = $current.id
            config = @{
                properties = $Properties
            }
        }
    }
    return Invoke-NifiJson -Context $Context -Method "PUT" -Path "/controller-services/$ControllerServiceId" -Body $body
}

function Set-ControllerServiceState {
    param(
        [object]$Context,
        [string]$ControllerServiceId,
        [ValidateSet("ENABLED", "DISABLED")]
        [string]$State
    )

    $current = Get-ControllerServiceEntity -Context $Context -ControllerServiceId $ControllerServiceId
    $body = @{
        revision = $current.revision
        state = $State
    }
    Invoke-NifiJson -Context $Context -Method "PUT" -Path "/controller-services/$ControllerServiceId/run-status" -Body $body | Out-Null
}

function Wait-ControllerServiceState {
    param(
        [object]$Context,
        [string]$ControllerServiceId,
        [string]$ExpectedState,
        [int]$TimeoutSeconds = 60
    )

    # Controller Service 的啟用是非同步操作，因此必須輪詢實際狀態後才能建立依賴它的流程。
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $entity = Get-ControllerServiceEntity -Context $Context -ControllerServiceId $ControllerServiceId
        $state = $entity.component.state
        if ($state -eq $ExpectedState) {
            return
        }
        if ($state -eq "ERROR") {
            throw "Controller Service $ControllerServiceId 啟用失敗，請檢查驗證錯誤。"
        }
        Start-Sleep -Seconds 1
    }

    throw "等待 Controller Service $ControllerServiceId 進入 $ExpectedState 逾時。"
}

function Get-ProcessorType {
    param(
        [object]$Context,
        [string]$Type
    )

    $types = Invoke-NifiJson -Context $Context -Method "GET" -Path "/flow/processor-types"
    $match = @($types.processorTypes | Where-Object { $_.type -eq $Type } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        throw "NiFi 尚未註冊 Processor type：$Type"
    }

    return $match[0]
}

function Get-ControllerServiceType {
    param(
        [object]$Context,
        [string]$Type
    )

    $types = Invoke-NifiJson -Context $Context -Method "GET" -Path "/flow/controller-service-types"
    $match = @($types.controllerServiceTypes | Where-Object { $_.type -eq $Type } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        throw "NiFi 尚未註冊 Controller Service type：$Type"
    }

    return $match[0]
}

function New-Processor {
    param(
        [object]$Context,
        [string]$ParentGroupId,
        [string]$Name,
        [string]$Type,
        [object]$Bundle,
        [double]$PositionX,
        [double]$PositionY
    )

    $body = @{
        revision = New-Revision -Context $Context
        component = @{
            name = $Name
            type = $Type
            bundle = @{
                group = $Bundle.group
                artifact = $Bundle.artifact
                version = $Bundle.version
            }
            position = @{
                x = $PositionX
                y = $PositionY
            }
        }
    }

    $entity = Invoke-NifiJson -Context $Context -Method "POST" -Path "/process-groups/$ParentGroupId/processors" -Body $body
    $Context.CreatedProcessorIds.Add($entity.id)
    return $entity
}

function New-ControllerService {
    param(
        [object]$Context,
        [string]$ParentGroupId,
        [string]$Name,
        [string]$Type,
        [object]$Bundle
    )

    $body = @{
        revision = New-Revision -Context $Context
        component = @{
            name = $Name
            type = $Type
            bundle = @{
                group = $Bundle.group
                artifact = $Bundle.artifact
                version = $Bundle.version
            }
        }
    }

    $entity = Invoke-NifiJson -Context $Context -Method "POST" -Path "/process-groups/$ParentGroupId/controller-services" -Body $body
    $Context.CreatedControllerServiceIds.Add($entity.id)
    return $entity
}

function New-Connection {
    param(
        [object]$Context,
        [string]$ParentGroupId,
        [string]$Name,
        [string]$SourceId,
        [string]$DestinationId,
        [string[]]$Relationships
    )

    $body = @{
        revision = New-Revision -Context $Context
        component = @{
            name = $Name
            source = @{
                id = $SourceId
                groupId = $ParentGroupId
                type = "PROCESSOR"
            }
            destination = @{
                id = $DestinationId
                groupId = $ParentGroupId
                type = "PROCESSOR"
            }
            selectedRelationships = $Relationships
        }
    }

    return Invoke-NifiJson -Context $Context -Method "POST" -Path "/process-groups/$ParentGroupId/connections" -Body $body
}

function Get-NarIdentifier {
    param([object]$Entity)

    if ($null -ne $Entity.narSummary.identifier) {
        return $Entity.narSummary.identifier
    }
    if ($null -ne $Entity.identifier) {
        return $Entity.identifier
    }
    throw "NAR upload response 沒有 identifier。"
}

function Wait-NarInstallation {
    param(
        [object]$Context,
        [string]$NarId
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $entity = Invoke-NifiJson -Context $Context -Method "GET" -Path "/controller/nar-manager/nars/$NarId"
        $summary = if ($null -ne $entity.narSummary) { $entity.narSummary } else { $entity }
        if ($summary.failureMessage) {
            throw "NAR 安裝失敗：$($summary.failureMessage)"
        }
        if ($summary.installComplete -eq $true) {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "等待 NAR 安裝逾時，請查看 NiFi log。"
}

function Install-NifiNar {
    param(
        [object]$Context,
        [string]$NarPath
    )

    $narFileName = [IO.Path]::GetFileName($NarPath)
    $uploadArguments = @(
        "-k"
        "-sS"
        "--fail-with-body"
        "-X"
        "POST"
        "$($Context.ApiBaseUrl)/controller/nar-manager/nars/content"
        "-H"
        "Authorization: Bearer $($Context.AccessToken)"
        "-H"
        "Accept: application/json"
        "-H"
        "Content-Type: application/octet-stream"
        "-H"
        "filename: $narFileName"
        "--data-binary"
        "@$NarPath"
    )
    $uploadResponse = ((& curl.exe @uploadArguments 2>&1) -join [Environment]::NewLine).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "NAR upload 失敗：$uploadResponse"
    }
    $narEntity = $uploadResponse | ConvertFrom-Json
    $narId = Get-NarIdentifier -Entity $narEntity
    Write-Host "已上傳 NAR，等待安裝：$narId"
    Wait-NarInstallation -Context $Context -NarId $narId
    Write-Host "NAR 安裝完成。"
}

function Wait-QueueHasFlowFile {
    param(
        [object]$Context,
        [string]$ConnectionId,
        [int]$TimeoutSeconds = 60
    )

    # Queue listing 先建立請求再非同步產生結果，輪詢可避免在 FlowFile 尚未可讀時誤判失敗。
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $listingEntity = Invoke-NifiJson -Context $Context -Method "POST" `
            -Path "/flowfile-queues/$ConnectionId/listing-requests"
        $listingId = $listingEntity.listingRequest.id
        if ([string]::IsNullOrWhiteSpace($listingId)) {
            throw "Queue listing response 沒有 request id。"
        }

        while ([DateTime]::UtcNow -lt $deadline) {
            $listingEntity = Invoke-NifiJson -Context $Context -Method "GET" `
                -Path "/flowfile-queues/$ConnectionId/listing-requests/$listingId"
            $listingRequest = $listingEntity.listingRequest
            if ($listingRequest.finished -eq $true) {
                if ($listingRequest.failureReason) {
                    throw "Queue listing 失敗：$($listingRequest.failureReason)"
                }
                $summaries = @($listingRequest.flowFileSummaries)
                if ($summaries.Count -gt 0) {
                    return $summaries
                }
                break
            }
            Start-Sleep -Seconds 1
        }

        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 1
        }
    }

    throw "等待 Queue FlowFile 逾時（$TimeoutSeconds 秒）。"
}

function Get-FlowFileEntity {
    param(
        [object]$Context,
        [string]$ConnectionId,
        [string]$FlowFileId
    )

    return Invoke-NifiJson -Context $Context -Method "GET" -Path "/flowfile-queues/$ConnectionId/flowfiles/$FlowFileId"
}

function Get-FlowFileContent {
    param(
        [object]$Context,
        [string]$ConnectionId,
        [string]$FlowFileId
    )

    return Invoke-NifiContent -Context $Context -Path "/flowfile-queues/$ConnectionId/flowfiles/$FlowFileId/content"
}

function Drop-QueueFlowFiles {
    param(
        [object]$Context,
        [string]$ConnectionId
    )

    $dropEntity = Invoke-NifiJson -Context $Context -Method "POST" `
        -Path "/flowfile-queues/$ConnectionId/drop-requests"
    $dropId = $dropEntity.dropRequest.id
    if ([string]::IsNullOrWhiteSpace($dropId)) {
        throw "Drop request response 沒有 request id。"
    }

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $dropEntity = Invoke-NifiJson -Context $Context -Method "GET" `
            -Path "/flowfile-queues/$ConnectionId/drop-requests/$dropId"
        $dropRequest = $dropEntity.dropRequest
        if ($dropRequest.finished -eq $true) {
            if ($dropRequest.failureReason) {
                throw "Queue 清除失敗：$($dropRequest.failureReason)"
            }
            return
        }
        Start-Sleep -Seconds 1
    }

    throw "等待 Queue 清除逾時。"
}

function Remove-NifiProcessGroup {
    param(
        [object]$Context,
        [string]$GroupId
    )

    # 先停止元件、清空佇列並停用 Controller Service，才能安全刪除整個 Process Group。
    foreach ($processorId in $Context.CreatedProcessorIds) {
        Stop-Processor -Context $Context -ProcessorId $processorId
    }

    $flow = Invoke-NifiJson -Context $Context -Method "GET" `
        -Path "/flow/process-groups/$GroupId"
    foreach ($connection in @($flow.processGroupFlow.flow.connections)) {
        $queued = $connection.status.aggregateSnapshot.flowFilesQueued
        if ($queued -gt 0) {
            Drop-QueueFlowFiles -Context $Context -ConnectionId $connection.component.id
        }
    }

    foreach ($controllerServiceId in $Context.CreatedControllerServiceIds) {
        Set-ControllerServiceState -Context $Context -ControllerServiceId $controllerServiceId -State "DISABLED"
        Wait-ControllerServiceState -Context $Context -ControllerServiceId $controllerServiceId -ExpectedState "DISABLED"
    }

    $group = Invoke-NifiJson -Context $Context -Method "GET" -Path "/process-groups/$GroupId"
    $version = $group.revision.version
    $deletePath = "/process-groups/${GroupId}?version=${version}&clientId=$($Context.ClientId)"
    Invoke-NifiJson -Context $Context -Method "DELETE" -Path $deletePath | Out-Null
    Write-Host "已刪除 Process Group：$GroupId"
}
