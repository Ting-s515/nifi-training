[CmdletBinding()]
param(
    [string]$BaseUrl = "https://localhost:8443/nifi-api",
    [string]$GroupName = "training-lab-11-spi",
    [switch]$SkipNarUpload,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
$apiBaseUrl = $BaseUrl.TrimEnd("/")
$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\")).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..")).Path
$envPath = Join-Path $repositoryRoot ".env"
$narPath = Join-Path $projectDirectory "nifi-training-custom-processor-nar\target\nifi-training-custom-processor-nar-1.0.0.nar"
$processorType = "com.example.nifi.training.ContentDigestProcessor"
$processorGroup = "com.example.nifi.training"
$processorArtifact = "nifi-training-custom-processor-nar"
$processorVersion = "1.0.0"
$clientId = [guid]::NewGuid().ToString()
$createdGroupId = $null
$createdProcessorIds = [System.Collections.Generic.List[string]]::new()

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

function Get-ProcessorType {
    param([string]$Type)

    $types = Invoke-NifiJson -Method "GET" -Path "/flow/processor-types"
    $match = @($types.processorTypes | Where-Object { $_.type -eq $Type } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        throw "NiFi 尚未註冊 Processor type：$Type"
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

function Get-FlowFileAttributes {
    param(
        [string]$ConnectionId,
        [string]$FlowFileId
    )

    $entity = Invoke-NifiJson -Method "GET" -Path "/flowfile-queues/$ConnectionId/flowfiles/$FlowFileId"
    return $entity.flowFile.attributes
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

    $standardGenerate = Get-ProcessorType -Type "org.apache.nifi.processors.standard.GenerateFlowFile"
    $standardLog = Get-ProcessorType -Type "org.apache.nifi.processors.standard.LogAttribute"
    $generate = New-Processor -ParentGroupId $createdGroupId -Name "Generate training FlowFile" `
        -Type $standardGenerate.type -Bundle $standardGenerate.bundle -PositionX 0 -PositionY 0
    $digest = New-Processor -ParentGroupId $createdGroupId -Name "Content Digest" `
        -Type $processorType -Bundle $customBundle -PositionX 400 -PositionY 0
    $successLog = New-Processor -ParentGroupId $createdGroupId -Name "Log digest success" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 800 -PositionY -100
    $failureLog = New-Processor -ParentGroupId $createdGroupId -Name "Log digest failure" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 800 -PositionY 200

    Set-AutoTerminate -ProcessorId $successLog.id -Relationships @("success")
    Set-AutoTerminate -ProcessorId $failureLog.id -Relationships @("success")

    $sourceConnection = New-Connection -ParentGroupId $createdGroupId -Name "source to digest" `
        -SourceId $generate.id -DestinationId $digest.id -Relationships @("success")
    $successConnection = New-Connection -ParentGroupId $createdGroupId -Name "digest success" `
        -SourceId $digest.id -DestinationId $successLog.id -Relationships @("success")
    New-Connection -ParentGroupId $createdGroupId -Name "digest failure" `
        -SourceId $digest.id -DestinationId $failureLog.id -Relationships @("failure") | Out-Null
    Write-Host "已建立 source、success、failure 三條連線。"

    Invoke-ProcessorOnce -ProcessorId $generate.id
    Wait-QueueHasFlowFile -ConnectionId $sourceConnection.id | Out-Null
    Invoke-ProcessorOnce -ProcessorId $digest.id
    $successSummaries = @(Wait-QueueHasFlowFile -ConnectionId $successConnection.id)
    $summary = @($successSummaries | Select-Object -First 1)
    $attributes = Get-FlowFileAttributes -ConnectionId $successConnection.id -FlowFileId $summary[0].uuid
    $digestValue = $attributes.'content.digest'
    if ($digestValue -notmatch '^[0-9a-f]{64}$') {
        throw "content.digest 不是預期的 SHA-256 十六進位值：$digestValue"
    }

    Write-Host "驗證成功：FlowFile content.digest = $digestValue"
    Write-Host "可在 NiFi UI 開啟 Process Group '$GroupName' 觀察 queue 與 Processor。"
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
