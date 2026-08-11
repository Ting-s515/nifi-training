[CmdletBinding()]
param(
    [string]$BaseUrl = "https://localhost:8443/nifi-api",
    [string]$GroupName = "training-lab-11-json-validation",
    [switch]$SkipNarUpload,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
$apiBaseUrl = $BaseUrl.TrimEnd("/")
$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\")).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..")).Path
$envPath = Join-Path $repositoryRoot ".env"
$narPath = Join-Path $projectDirectory "nifi-training-custom-processor-nar\target\nifi-training-custom-processor-nar-2.0.0.nar"
$processorType = "com.example.nifi.training.ValidateOrderJsonProcessor"
$processorGroup = "com.example.nifi.training"
$processorArtifact = "nifi-training-custom-processor-nar"
$processorVersion = "2.0.0"
$readerType = "org.apache.nifi.json.JsonTreeReader"
$readerGroup = "org.apache.nifi"
$readerArtifact = "nifi-record-serialization-services-nar"
$readerVersion = "2.9.0"
$clientId = [guid]::NewGuid().ToString()
$createdGroupId = $null
$createdProcessorIds = [System.Collections.Generic.List[string]]::new()
$createdControllerServiceIds = [System.Collections.Generic.List[string]]::new()
$orderSchema = @'
{
  "type": "record",
  "name": "TrainingOrder",
  "fields": [
    {"name": "order_id", "type": ["null", "string"], "default": null},
    {"name": "customer", "type": ["null", "string"], "default": null},
    {"name": "amount", "type": ["null", "double"], "default": null}
  ]
}
'@
$validationCases = @(
    [PSCustomObject]@{
        Name = "valid order"
        ProcessorName = "Generate valid order"
        Content = '{"order_id":"1001","customer":"Alice","amount":120.50}'
        ExpectedConnection = "success"
        ExpectedStatus = "valid"
        ExpectedReason = "accepted"
    }
    [PSCustomObject]@{
        Name = "missing customer"
        ProcessorName = "Generate missing customer order"
        Content = '{"order_id":"1002","amount":80.00}'
        ExpectedConnection = "failure"
        ExpectedStatus = "invalid"
        ExpectedReason = "customer.required"
    }
    [PSCustomObject]@{
        Name = "invalid amount"
        ProcessorName = "Generate invalid amount order"
        Content = '{"order_id":"1003","customer":"Carol","amount":0}'
        ExpectedConnection = "failure"
        ExpectedStatus = "invalid"
        ExpectedReason = "amount.positive"
    }
)

function Convert-ToJsonBody {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-NifiJson {
    param(
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
        "$apiBaseUrl$Path"
        "-H"
        "Authorization: Bearer $script:accessToken"
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
    param([string]$Path)

    $curlArguments = @(
        "-k"
        "-sS"
        "--fail-with-body"
        "$apiBaseUrl$Path"
        "-H"
        "Authorization: Bearer $script:accessToken"
    )
    $response = & curl.exe @curlArguments 2>&1
    $responseText = ($response -join [Environment]::NewLine)
    if ($LASTEXITCODE -ne 0) {
        throw "NiFi content API GET $Path 失敗：$responseText"
    }

    return $responseText.Trim()
}

function New-Revision {
    return @{
        clientId = $clientId
        version = 0
    }
}

function Get-ProcessorEntity {
    param([string]$ProcessorId)

    return Invoke-NifiJson -Method "GET" -Path "/processors/$ProcessorId"
}

function Get-ControllerServiceEntity {
    param([string]$ControllerServiceId)

    return Invoke-NifiJson -Method "GET" -Path "/controller-services/$ControllerServiceId"
}

function Invoke-ProcessorOnce {
    param([string]$ProcessorId)

    $current = Get-ProcessorEntity -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        state = "RUN_ONCE"
    }
    Invoke-NifiJson -Method "PUT" -Path "/processors/$ProcessorId/run-status" -Body $body | Out-Null
}

function Stop-Processor {
    param([string]$ProcessorId)

    $current = Get-ProcessorEntity -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        state = "STOPPED"
    }
    Invoke-NifiJson -Method "PUT" -Path "/processors/$ProcessorId/run-status" -Body $body | Out-Null
}

function Set-ProcessorProperties {
    param(
        [string]$ProcessorId,
        [hashtable]$Properties
    )

    $current = Get-ProcessorEntity -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        component = @{
            id = $current.id
            config = @{
                properties = $Properties
            }
        }
    }
    return Invoke-NifiJson -Method "PUT" -Path "/processors/$ProcessorId" -Body $body
}

function Set-AutoTerminate {
    param(
        [string]$ProcessorId,
        [string[]]$Relationships
    )

    $current = Get-ProcessorEntity -ProcessorId $ProcessorId
    $body = @{
        revision = $current.revision
        component = @{
            id = $current.id
            config = @{
                autoTerminatedRelationships = $Relationships
            }
        }
    }
    Invoke-NifiJson -Method "PUT" -Path "/processors/$ProcessorId" -Body $body | Out-Null
}

function Set-ControllerServiceProperties {
    param(
        [string]$ControllerServiceId,
        [hashtable]$Properties
    )

    $current = Get-ControllerServiceEntity -ControllerServiceId $ControllerServiceId
    $body = @{
        revision = $current.revision
        component = @{
            id = $current.id
            config = @{
                properties = $Properties
            }
        }
    }
    return Invoke-NifiJson -Method "PUT" -Path "/controller-services/$ControllerServiceId" -Body $body
}

function Set-ControllerServiceState {
    param(
        [string]$ControllerServiceId,
        [ValidateSet("ENABLED", "DISABLED")]
        [string]$State
    )

    $current = Get-ControllerServiceEntity -ControllerServiceId $ControllerServiceId
    $body = @{
        revision = $current.revision
        state = $State
    }
    Invoke-NifiJson -Method "PUT" -Path "/controller-services/$ControllerServiceId/run-status" -Body $body | Out-Null
}

function Wait-ControllerServiceState {
    param(
        [string]$ControllerServiceId,
        [string]$ExpectedState,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $entity = Get-ControllerServiceEntity -ControllerServiceId $ControllerServiceId
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
    param([string]$Type)

    $types = Invoke-NifiJson -Method "GET" -Path "/flow/processor-types"
    $match = @($types.processorTypes | Where-Object { $_.type -eq $Type } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        throw "NiFi 尚未註冊 Processor type：$Type"
    }

    return $match[0]
}

function Get-ControllerServiceType {
    param([string]$Type)

    $types = Invoke-NifiJson -Method "GET" -Path "/flow/controller-service-types"
    $match = @($types.controllerServiceTypes | Where-Object { $_.type -eq $Type } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        throw "NiFi 尚未註冊 Controller Service type：$Type"
    }

    return $match[0]
}

function New-Processor {
    param(
        [string]$ParentGroupId,
        [string]$Name,
        [string]$Type,
        [object]$Bundle,
        [double]$PositionX,
        [double]$PositionY
    )

    $body = @{
        revision = New-Revision
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

    $entity = Invoke-NifiJson -Method "POST" -Path "/process-groups/$ParentGroupId/processors" -Body $body
    $createdProcessorIds.Add($entity.id)
    return $entity
}

function New-ControllerService {
    param(
        [string]$ParentGroupId,
        [string]$Name,
        [string]$Type,
        [object]$Bundle
    )

    $body = @{
        revision = New-Revision
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

    $entity = Invoke-NifiJson -Method "POST" -Path "/process-groups/$ParentGroupId/controller-services" -Body $body
    $createdControllerServiceIds.Add($entity.id)
    return $entity
}

function New-Connection {
    param(
        [string]$ParentGroupId,
        [string]$Name,
        [string]$SourceId,
        [string]$DestinationId,
        [string[]]$Relationships
    )

    $body = @{
        revision = New-Revision
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

    return Invoke-NifiJson -Method "POST" -Path "/process-groups/$ParentGroupId/connections" -Body $body
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
    param([string]$NarId)

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $entity = Invoke-NifiJson -Method "GET" -Path "/controller/nar-manager/nars/$NarId"
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

function Wait-QueueHasFlowFile {
    param(
        [string]$ConnectionId,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $listingEntity = Invoke-NifiJson -Method "POST" `
            -Path "/flowfile-queues/$ConnectionId/listing-requests"
        $listingId = $listingEntity.listingRequest.id
        if ([string]::IsNullOrWhiteSpace($listingId)) {
            throw "Queue listing response 沒有 request id。"
        }

        while ([DateTime]::UtcNow -lt $deadline) {
            $listingEntity = Invoke-NifiJson -Method "GET" `
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
        [string]$ConnectionId,
        [string]$FlowFileId
    )

    return Invoke-NifiJson -Method "GET" -Path "/flowfile-queues/$ConnectionId/flowfiles/$FlowFileId"
}

function Get-FlowFileContent {
    param(
        [string]$ConnectionId,
        [string]$FlowFileId
    )

    return Invoke-NifiContent -Path "/flowfile-queues/$ConnectionId/flowfiles/$FlowFileId/content"
}

function Drop-QueueFlowFiles {
    param([string]$ConnectionId)

    $dropEntity = Invoke-NifiJson -Method "POST" `
        -Path "/flowfile-queues/$ConnectionId/drop-requests"
    $dropId = $dropEntity.dropRequest.id
    if ([string]::IsNullOrWhiteSpace($dropId)) {
        throw "Drop request response 沒有 request id。"
    }

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $dropEntity = Invoke-NifiJson -Method "GET" `
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

function Invoke-ValidationCase {
    param(
        [object]$Case,
        [string]$SourceProcessorId,
        [string]$SourceConnectionId,
        [string]$SuccessConnectionId,
        [string]$FailureConnectionId,
        [string]$ValidatorProcessorId
    )

    Invoke-ProcessorOnce -ProcessorId $SourceProcessorId
    Wait-QueueHasFlowFile -ConnectionId $SourceConnectionId | Out-Null
    Invoke-ProcessorOnce -ProcessorId $ValidatorProcessorId

    $expectedConnectionId = if ($Case.ExpectedConnection -eq "success") {
        $SuccessConnectionId
    } else {
        $FailureConnectionId
    }
    $summaries = @(Wait-QueueHasFlowFile -ConnectionId $expectedConnectionId)
    if ($summaries.Count -ne 1) {
        throw "測試案例 '$($Case.Name)' 預期一筆 FlowFile，實際取得 $($summaries.Count) 筆。"
    }

    $summary = $summaries[0]
    $flowFile = Get-FlowFileEntity -ConnectionId $expectedConnectionId -FlowFileId $summary.uuid
    $attributes = $flowFile.flowFile.attributes
    if ($attributes.'training.validation.status' -ne $Case.ExpectedStatus) {
        throw "測試案例 '$($Case.Name)' status 不符：$($attributes.'training.validation.status')"
    }
    if ($attributes.'training.validation.reason' -ne $Case.ExpectedReason) {
        throw "測試案例 '$($Case.Name)' reason 不符：$($attributes.'training.validation.reason')"
    }

    $content = Get-FlowFileContent -ConnectionId $expectedConnectionId -FlowFileId $summary.uuid
    if ($content -ne $Case.Content) {
        throw "測試案例 '$($Case.Name)' 的 FlowFile content 被意外修改：$content"
    }

    Drop-QueueFlowFiles -ConnectionId $expectedConnectionId
    Write-Host "驗證通過：$($Case.Name) -> $($Case.ExpectedConnection) ($($Case.ExpectedReason))"
}

try {
    if (-not (Test-Path -LiteralPath $envPath)) {
        throw "找不到根目錄 .env：$envPath"
    }
    if (-not $SkipNarUpload -and -not (Test-Path -LiteralPath $narPath)) {
        throw "找不到 NAR，請先執行 build.ps1：$narPath"
    }

    $envValues = Get-Content -Raw -Encoding UTF8 -LiteralPath $envPath | ConvertFrom-StringData
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
        "$apiBaseUrl/access/token"
        "-H"
        "Content-Type: application/x-www-form-urlencoded"
        "--data-urlencode"
        "username=$username"
        "--data-urlencode"
        "password=$password"
    )
    $script:accessToken = ((& curl.exe @tokenArguments 2>&1) -join [Environment]::NewLine).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($script:accessToken)) {
        throw "無法取得 NiFi access token。"
    }
    Write-Host "已取得 NiFi access token。"

    if (-not $SkipNarUpload) {
        $narFileName = [IO.Path]::GetFileName($narPath)
        $uploadArguments = @(
            "-k"
            "-sS"
            "--fail-with-body"
            "-X"
            "POST"
            "$apiBaseUrl/controller/nar-manager/nars/content"
            "-H"
            "Authorization: Bearer $script:accessToken"
            "-H"
            "Accept: application/json"
            "-H"
            "Content-Type: application/octet-stream"
            "-H"
            "filename: $narFileName"
            "--data-binary"
            "@$narPath"
        )
        $uploadResponse = ((& curl.exe @uploadArguments 2>&1) -join [Environment]::NewLine).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "NAR upload 失敗：$uploadResponse"
        }
        $narEntity = $uploadResponse | ConvertFrom-Json
        $narId = Get-NarIdentifier -Entity $narEntity
        Write-Host "已上傳 NAR，等待安裝：$narId"
        Wait-NarInstallation -NarId $narId
        Write-Host "NAR 安裝完成。"
    }

    $customType = Get-ProcessorType -Type $processorType
    $customBundle = $customType.bundle
    if ($customBundle.group -ne $processorGroup -or
        $customBundle.artifact -ne $processorArtifact -or
        $customBundle.version -ne $processorVersion) {
        throw "Processor type 的 Bundle 資訊與範例預期不一致。"
    }
    Write-Host "已驗證 Processor type：$processorType"

    $readerServiceType = Get-ControllerServiceType -Type $readerType
    $readerBundle = $readerServiceType.bundle
    if ($readerBundle.group -ne $readerGroup -or
        $readerBundle.artifact -ne $readerArtifact -or
        $readerBundle.version -ne $readerVersion) {
        throw "Controller Service type 的 Bundle 資訊與範例預期不一致。"
    }
    Write-Host "已驗證 Controller Service type：$readerType"

    $root = Invoke-NifiJson -Method "GET" -Path "/flow/process-groups/root"
    $rootGroupId = $root.processGroupFlow.id
    if ([string]::IsNullOrWhiteSpace($rootGroupId)) {
        throw "無法從 root flow response 取得 Process Group id。"
    }

    $groupBody = @{
        revision = New-Revision
        component = @{
            name = $GroupName
            position = @{ x = 0.0; y = 0.0 }
        }
    }
    $groupEntity = Invoke-NifiJson -Method "POST" -Path "/process-groups/$rootGroupId/process-groups" -Body $groupBody
    $createdGroupId = $groupEntity.id
    Write-Host "已建立 Process Group：$GroupName ($createdGroupId)"

    $reader = New-ControllerService -ParentGroupId $createdGroupId -Name "JSON order reader" `
        -Type $readerType -Bundle $readerBundle
    Set-ControllerServiceProperties -ControllerServiceId $reader.id -Properties @{
        "Schema Access Strategy" = "schema-text-property"
        "Schema Text" = $orderSchema
    } | Out-Null
    Set-ControllerServiceState -ControllerServiceId $reader.id -State "ENABLED"
    Wait-ControllerServiceState -ControllerServiceId $reader.id -ExpectedState "ENABLED"
    Write-Host "已建立並啟用 JsonTreeReader Controller Service。"

    $standardGenerate = Get-ProcessorType -Type "org.apache.nifi.processors.standard.GenerateFlowFile"
    $standardLog = Get-ProcessorType -Type "org.apache.nifi.processors.standard.LogAttribute"
    $validator = New-Processor -ParentGroupId $createdGroupId -Name "Validate order JSON" `
        -Type $processorType -Bundle $customBundle -PositionX 500 -PositionY 100
    Set-ProcessorProperties -ProcessorId $validator.id -Properties @{
        "Record Reader" = $reader.id
    } | Out-Null

    $sourceProcessors = @{}
    $sourceConnections = @{}
    $positionY = -200
    foreach ($case in $validationCases) {
        $source = New-Processor -ParentGroupId $createdGroupId -Name $case.ProcessorName `
            -Type $standardGenerate.type -Bundle $standardGenerate.bundle -PositionX 0 -PositionY $positionY
        Set-ProcessorProperties -ProcessorId $source.id -Properties @{
            "Data Format" = "Text"
            "Custom Text" = $case.Content
        } | Out-Null
        $sourceConnection = New-Connection -ParentGroupId $createdGroupId -Name "$($case.Name) to validator" `
            -SourceId $source.id -DestinationId $validator.id -Relationships @("success")
        $sourceProcessors[$case.Name] = $source
        $sourceConnections[$case.Name] = $sourceConnection
        $positionY += 200
    }

    $successLog = New-Processor -ParentGroupId $createdGroupId -Name "Log valid order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 0
    $failureLog = New-Processor -ParentGroupId $createdGroupId -Name "Log invalid order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 300
    Set-AutoTerminate -ProcessorId $successLog.id -Relationships @("success")
    Set-AutoTerminate -ProcessorId $failureLog.id -Relationships @("success")

    $successConnection = New-Connection -ParentGroupId $createdGroupId -Name "validator success" `
        -SourceId $validator.id -DestinationId $successLog.id -Relationships @("success")
    $failureConnection = New-Connection -ParentGroupId $createdGroupId -Name "validator failure" `
        -SourceId $validator.id -DestinationId $failureLog.id -Relationships @("failure")
    Write-Host "已建立三個輸入案例、success/failure 分流與 LogAttribute 下游。"

    foreach ($case in $validationCases) {
        Invoke-ValidationCase -Case $case `
            -SourceProcessorId $sourceProcessors[$case.Name].id `
            -SourceConnectionId $sourceConnections[$case.Name].id `
            -SuccessConnectionId $successConnection.id `
            -FailureConnectionId $failureConnection.id `
            -ValidatorProcessorId $validator.id
    }

    Write-Host "全部驗證成功：三種 JSON 訂單案例均已依預期分流。"
    Write-Host "可在 NiFi UI 開啟 Process Group '$GroupName' 觀察 Controller Service、Processor 與 queue。"
} finally {
    if ($Cleanup -and $createdGroupId) {
        try {
            foreach ($processorId in $createdProcessorIds) {
                Stop-Processor -ProcessorId $processorId
            }

            $flow = Invoke-NifiJson -Method "GET" `
                -Path "/flow/process-groups/$createdGroupId"
            foreach ($connection in @($flow.processGroupFlow.flow.connections)) {
                $queued = $connection.status.aggregateSnapshot.flowFilesQueued
                if ($queued -gt 0) {
                    Drop-QueueFlowFiles -ConnectionId $connection.component.id
                }
            }

            foreach ($controllerServiceId in $createdControllerServiceIds) {
                Set-ControllerServiceState -ControllerServiceId $controllerServiceId -State "DISABLED"
                Wait-ControllerServiceState -ControllerServiceId $controllerServiceId -ExpectedState "DISABLED"
            }

            $group = Invoke-NifiJson -Method "GET" -Path "/process-groups/$createdGroupId"
            $version = $group.revision.version
            $deletePath = "/process-groups/${createdGroupId}?version=${version}&clientId=${clientId}"
            Invoke-NifiJson -Method "DELETE" -Path $deletePath | Out-Null
            Write-Host "已刪除 Process Group：$createdGroupId"
        } catch {
            Write-Warning "Cleanup 失敗，請在 NiFi UI 手動刪除 Process Group $createdGroupId：$($_.Exception.Message)"
        }
    }
}
