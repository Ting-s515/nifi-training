[CmdletBinding()]
param(
    [string]$BaseUrl = "https://localhost:8443/nifi-api",
    [string]$GroupName = "training-lab-11-json-validation",
    [switch]$SkipNarUpload,
    [switch]$ReplaceExisting,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "nifi-flow-helper.ps1")

$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..")).Path
$envPath = Join-Path $repositoryRoot ".env"
$narPath = Join-Path $projectDirectory "nifi-training-custom-processor-nar\target\nifi-training-custom-processor-nar-2.1.0.nar"
$processorType = "com.example.nifi.training.ValidateOrderJsonProcessor"
$processorGroup = "com.example.nifi.training"
$processorArtifact = "nifi-training-custom-processor-nar"
$processorVersion = "2.1.0"
$readerType = "org.apache.nifi.json.JsonTreeReader"
$readerGroup = "org.apache.nifi"
$readerArtifact = "nifi-record-serialization-services-nar"
$readerVersion = "2.9.0"
$context = New-NifiContext -BaseUrl $BaseUrl
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

function Invoke-ValidationCase {
    param(
        [object]$Case,
        [object]$Context,
        [string]$SourceProcessorId,
        [string]$SourceConnectionId,
        [string]$SuccessConnectionId,
        [string]$FailureConnectionId,
        [string]$ValidatorProcessorId
    )

    Invoke-ProcessorOnce -Context $Context -ProcessorId $SourceProcessorId
    Wait-QueueHasFlowFile -Context $Context -ConnectionId $SourceConnectionId | Out-Null
    Invoke-ProcessorOnce -Context $Context -ProcessorId $ValidatorProcessorId

    $expectedConnectionId = if ($Case.ExpectedConnection -eq "success") {
        $SuccessConnectionId
    } else {
        $FailureConnectionId
    }
    $summaries = @(Wait-QueueHasFlowFile -Context $Context -ConnectionId $expectedConnectionId)
    if ($summaries.Count -ne 1) {
        throw "測試案例 '$($Case.Name)' 預期一筆 FlowFile，實際取得 $($summaries.Count) 筆。"
    }

    $summary = $summaries[0]
    $flowFile = Get-FlowFileEntity -Context $Context -ConnectionId $expectedConnectionId -FlowFileId $summary.uuid
    $attributes = $flowFile.flowFile.attributes
    if ($attributes.'training.validation.status' -ne $Case.ExpectedStatus) {
        throw "測試案例 '$($Case.Name)' status 不符：$($attributes.'training.validation.status')"
    }
    if ($attributes.'training.validation.reason' -ne $Case.ExpectedReason) {
        throw "測試案例 '$($Case.Name)' reason 不符：$($attributes.'training.validation.reason')"
    }

    $content = Get-FlowFileContent -Context $Context -ConnectionId $expectedConnectionId -FlowFileId $summary.uuid
    if ($content -ne $Case.Content) {
        throw "測試案例 '$($Case.Name)' 的 FlowFile content 被意外修改：$content"
    }

    Drop-QueueFlowFiles -Context $Context -ConnectionId $expectedConnectionId
    Write-Host "驗證通過：$($Case.Name) -> $($Case.ExpectedConnection) ($($Case.ExpectedReason))"
}

try {
    if (-not $SkipNarUpload -and -not (Test-Path -LiteralPath $narPath)) {
        throw "找不到 NAR，請先執行 build.ps1：$narPath"
    }

    Set-NifiAccessToken -Context $context -EnvPath $envPath
    Write-Host "已取得 NiFi access token。"

    if (-not $SkipNarUpload) {
        Install-NifiNar -Context $context -NarPath $narPath
    }

    $customType = Get-ProcessorType -Context $context -Type $processorType
    $customBundle = $customType.bundle
    if ($customBundle.group -ne $processorGroup -or
        $customBundle.artifact -ne $processorArtifact -or
        $customBundle.version -ne $processorVersion) {
        throw "Processor type 的 Bundle 資訊與範例預期不一致。"
    }
    Write-Host "已驗證 Processor type：$processorType"

    $readerServiceType = Get-ControllerServiceType -Context $context -Type $readerType
    $readerBundle = $readerServiceType.bundle
    if ($readerBundle.group -ne $readerGroup -or
        $readerBundle.artifact -ne $readerArtifact -or
        $readerBundle.version -ne $readerVersion) {
        throw "Controller Service type 的 Bundle 資訊與範例預期不一致。"
    }
    Write-Host "已驗證 Controller Service type：$readerType"

    $root = Invoke-NifiJson -Context $context -Method "GET" -Path "/flow/process-groups/root"
    $rootGroupId = $root.processGroupFlow.id
    if ([string]::IsNullOrWhiteSpace($rootGroupId)) {
        throw "無法從 root flow response 取得 Process Group id。"
    }

    if ($ReplaceExisting) {
        Remove-NifiProcessGroupIfExists -Context $context -ParentGroupId $rootGroupId -GroupName $GroupName
    }

    $groupBody = @{
        revision = New-Revision -Context $context
        component = @{
            name = $GroupName
            position = @{ x = 0.0; y = 0.0 }
        }
    }
    $groupEntity = Invoke-NifiJson -Context $context -Method "POST" -Path "/process-groups/$rootGroupId/process-groups" -Body $groupBody
    $context.CreatedGroupId = $groupEntity.id
    Write-Host "已建立 Process Group：$GroupName ($($context.CreatedGroupId))"

    $reader = New-ControllerService -Context $context -ParentGroupId $context.CreatedGroupId -Name "JSON order reader" `
        -Type $readerType -Bundle $readerBundle
    Set-ControllerServiceProperties -Context $context -ControllerServiceId $reader.id -Properties @{
        "Schema Access Strategy" = "schema-text-property"
        "Schema Text" = $orderSchema
    } | Out-Null
    Set-ControllerServiceState -Context $context -ControllerServiceId $reader.id -State "ENABLED"
    Wait-ControllerServiceState -Context $context -ControllerServiceId $reader.id -ExpectedState "ENABLED"
    Write-Host "已建立並啟用 JsonTreeReader Controller Service。"

    $standardGenerate = Get-ProcessorType -Context $context -Type "org.apache.nifi.processors.standard.GenerateFlowFile"
    $standardLog = Get-ProcessorType -Context $context -Type "org.apache.nifi.processors.standard.LogAttribute"
    $validator = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Validate order JSON" `
        -Type $processorType -Bundle $customBundle -PositionX 500 -PositionY 100
    Set-ProcessorProperties -Context $context -ProcessorId $validator.id -Properties @{
        "Record Reader" = $reader.id
    } | Out-Null

    $sourceProcessors = @{}
    $sourceConnections = @{}
    $positionY = -200
    foreach ($case in $validationCases) {
        $source = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name $case.ProcessorName `
            -Type $standardGenerate.type -Bundle $standardGenerate.bundle -PositionX 0 -PositionY $positionY
        Set-ProcessorProperties -Context $context -ProcessorId $source.id -Properties @{
            "Data Format" = "Text"
            "Custom Text" = $case.Content
        } | Out-Null
        $sourceConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "$($case.Name) to validator" `
            -SourceId $source.id -DestinationId $validator.id -Relationships @("success")
        $sourceProcessors[$case.Name] = $source
        $sourceConnections[$case.Name] = $sourceConnection
        $positionY += 200
    }

    $successLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Log valid order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 0
    $failureLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Log invalid order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 300
    Set-AutoTerminate -Context $context -ProcessorId $successLog.id -Relationships @("success")
    Set-AutoTerminate -Context $context -ProcessorId $failureLog.id -Relationships @("success")

    $successConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "validator success" `
        -SourceId $validator.id -DestinationId $successLog.id -Relationships @("success")
    $failureConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "validator failure" `
        -SourceId $validator.id -DestinationId $failureLog.id -Relationships @("failure")
    Write-Host "已建立三個輸入案例、success/failure 分流與 LogAttribute 下游。"

    foreach ($case in $validationCases) {
        Invoke-ValidationCase -Case $case `
            -Context $context `
            -SourceProcessorId $sourceProcessors[$case.Name].id `
            -SourceConnectionId $sourceConnections[$case.Name].id `
            -SuccessConnectionId $successConnection.id `
            -FailureConnectionId $failureConnection.id `
            -ValidatorProcessorId $validator.id
    }

    Write-Host "全部驗證成功：三種 JSON 訂單案例均已依預期分流。"
    Write-Host "可在 NiFi UI 開啟 Process Group '$GroupName' 觀察 Controller Service、Processor 與 queue。"
} finally {
    if ($Cleanup -and $context.CreatedGroupId) {
        try {
            Remove-NifiProcessGroup -Context $context -GroupId $context.CreatedGroupId
        } catch {
            Write-Warning "Cleanup 失敗，請在 NiFi UI 手動刪除 Process Group $($context.CreatedGroupId)：$($_.Exception.Message)"
        }
    }
}
