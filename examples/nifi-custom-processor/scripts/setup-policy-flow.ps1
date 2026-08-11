[CmdletBinding()]
param(
    [string]$BaseUrl = "https://localhost:8443/nifi-api",
    [string]$GroupName = "training-lab-11-order-policy",
    [switch]$SkipNarUpload,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "nifi-flow-helper.ps1")

$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..")).Path
$envPath = Join-Path $repositoryRoot ".env"
$narPath = Join-Path $projectDirectory "nifi-training-custom-processor-nar\target\nifi-training-custom-processor-nar-2.1.0.nar"
$processorType = "com.example.nifi.training.OrderPolicyProcessor"
$processorGroup = "com.example.nifi.training"
$processorArtifact = "nifi-training-custom-processor-nar"
$processorVersion = "2.1.0"
$readerType = "org.apache.nifi.json.JsonTreeReader"
$readerGroup = "org.apache.nifi"
$readerArtifact = "nifi-record-serialization-services-nar"
$readerVersion = "2.9.0"
$context = New-NifiContext -BaseUrl $BaseUrl
$policySchema = @'
{
  "type": "record",
  "name": "TrainingOrderPolicy",
  "fields": [
    {"name": "order_id", "type": ["null", "string"], "default": null},
    {"name": "customer", "type": ["null", "string"], "default": null},
    {"name": "customer_tier", "type": ["null", "string"], "default": null},
    {"name": "amount", "type": ["null", "double"], "default": null}
  ]
}
'@
$policyCases = @(
    [PSCustomObject]@{
        Name = "standard approved order"
        ProcessorName = "Generate standard approved order"
        Content = '{"order_id":"2001","customer":"Alice","customer_tier":"standard","amount":800}'
        ExpectedConnection = "approved"
        ExpectedDecision = "approved"
        ExpectedReason = "accepted"
    }
    [PSCustomObject]@{
        Name = "vip approved order"
        ProcessorName = "Generate vip approved order"
        Content = '{"order_id":"2002","customer":"Bob","customer_tier":"vip","amount":4500}'
        ExpectedConnection = "approved"
        ExpectedDecision = "approved"
        ExpectedReason = "accepted"
    }
    [PSCustomObject]@{
        Name = "standard manual review order"
        ProcessorName = "Generate standard manual review order"
        Content = '{"order_id":"2003","customer":"Carol","customer_tier":"standard","amount":1500}'
        ExpectedConnection = "manual-review"
        ExpectedDecision = "manual_review"
        ExpectedReason = "tier.amount.review"
    }
    [PSCustomObject]@{
        Name = "rejected high amount order"
        ProcessorName = "Generate rejected high amount order"
        Content = '{"order_id":"2004","customer":"Dora","customer_tier":"vip","amount":6000}'
        ExpectedConnection = "rejected"
        ExpectedDecision = "rejected"
        ExpectedReason = "amount.limit"
    }
    [PSCustomObject]@{
        Name = "missing tier order"
        ProcessorName = "Generate missing tier order"
        Content = '{"order_id":"2005","customer":"Eve","amount":100}'
        ExpectedConnection = "failure"
        ExpectedDecision = "error"
        ExpectedReason = "customer_tier.required"
    }
)

function Invoke-PolicyCase {
    param(
        [object]$Case,
        [object]$Context,
        [string]$SourceProcessorId,
        [string]$SourceConnectionId,
        [hashtable]$OutputConnections,
        [string]$PolicyProcessorId
    )

    Invoke-ProcessorOnce -Context $Context -ProcessorId $SourceProcessorId
    Wait-QueueHasFlowFile -Context $Context -ConnectionId $SourceConnectionId | Out-Null
    Invoke-ProcessorOnce -Context $Context -ProcessorId $PolicyProcessorId

    $expectedConnectionId = $OutputConnections[$Case.ExpectedConnection]
    $summaries = @(Wait-QueueHasFlowFile -Context $Context -ConnectionId $expectedConnectionId)
    if ($summaries.Count -ne 1) {
        throw "政策案例 '$($Case.Name)' 預期一筆 FlowFile，實際取得 $($summaries.Count) 筆。"
    }

    $summary = $summaries[0]
    $flowFile = Get-FlowFileEntity -Context $Context -ConnectionId $expectedConnectionId -FlowFileId $summary.uuid
    $attributes = $flowFile.flowFile.attributes
    if ($attributes.'training.policy.decision' -ne $Case.ExpectedDecision) {
        throw "政策案例 '$($Case.Name)' decision 不符：$($attributes.'training.policy.decision')"
    }
    if ($attributes.'training.policy.reason' -ne $Case.ExpectedReason) {
        throw "政策案例 '$($Case.Name)' reason 不符：$($attributes.'training.policy.reason')"
    }

    $content = Get-FlowFileContent -Context $Context -ConnectionId $expectedConnectionId -FlowFileId $summary.uuid
    if ($content -ne $Case.Content) {
        throw "政策案例 '$($Case.Name)' 的 FlowFile content 被意外修改：$content"
    }

    Drop-QueueFlowFiles -Context $Context -ConnectionId $expectedConnectionId
    Write-Host "政策驗證通過：$($Case.Name) -> $($Case.ExpectedConnection) ($($Case.ExpectedReason))"
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

    $reader = New-ControllerService -Context $context -ParentGroupId $context.CreatedGroupId -Name "JSON policy reader" `
        -Type $readerType -Bundle $readerBundle
    Set-ControllerServiceProperties -Context $context -ControllerServiceId $reader.id -Properties @{
        "Schema Access Strategy" = "schema-text-property"
        "Schema Text" = $policySchema
    } | Out-Null
    Set-ControllerServiceState -Context $context -ControllerServiceId $reader.id -State "ENABLED"
    Wait-ControllerServiceState -Context $context -ControllerServiceId $reader.id -ExpectedState "ENABLED"
    Write-Host "已建立並啟用 JsonTreeReader Controller Service。"

    $standardGenerate = Get-ProcessorType -Context $context -Type "org.apache.nifi.processors.standard.GenerateFlowFile"
    $standardLog = Get-ProcessorType -Context $context -Type "org.apache.nifi.processors.standard.LogAttribute"
    $policyProcessor = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Apply order policy" `
        -Type $processorType -Bundle $customBundle -PositionX 500 -PositionY 200
    Set-ProcessorProperties -Context $context -ProcessorId $policyProcessor.id -Properties @{
        "Record Reader" = $reader.id
        "Manual Review Threshold" = "1000"
        "Reject Threshold" = "5000"
        "VIP Customer Tier" = "vip"
    } | Out-Null

    $sourceProcessors = @{}
    $sourceConnections = @{}
    $positionY = -300
    foreach ($case in $policyCases) {
        $source = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name $case.ProcessorName `
            -Type $standardGenerate.type -Bundle $standardGenerate.bundle -PositionX 0 -PositionY $positionY
        Set-ProcessorProperties -Context $context -ProcessorId $source.id -Properties @{
            "Data Format" = "Text"
            "Custom Text" = $case.Content
        } | Out-Null
        $sourceConnection = New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "$($case.Name) to policy" `
            -SourceId $source.id -DestinationId $policyProcessor.id -Relationships @("success")
        $sourceProcessors[$case.Name] = $source
        $sourceConnections[$case.Name] = $sourceConnection
        $positionY += 170
    }

    $approvedLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Log approved order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY -100
    $manualReviewLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Log manual review order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 100
    $rejectedLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Log rejected order" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 300
    $failureLog = New-Processor -Context $context -ParentGroupId $context.CreatedGroupId -Name "Log policy failure" `
        -Type $standardLog.type -Bundle $standardLog.bundle -PositionX 1000 -PositionY 500
    foreach ($log in @($approvedLog, $manualReviewLog, $rejectedLog, $failureLog)) {
        Set-AutoTerminate -Context $context -ProcessorId $log.id -Relationships @("success")
    }

    $outputConnections = @{
        "approved" = (New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "policy approved" `
                -SourceId $policyProcessor.id -DestinationId $approvedLog.id -Relationships @("approved")).id
        "manual-review" = (New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "policy manual review" `
                -SourceId $policyProcessor.id -DestinationId $manualReviewLog.id -Relationships @("manual-review")).id
        "rejected" = (New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "policy rejected" `
                -SourceId $policyProcessor.id -DestinationId $rejectedLog.id -Relationships @("rejected")).id
        "failure" = (New-Connection -Context $context -ParentGroupId $context.CreatedGroupId -Name "policy failure" `
                -SourceId $policyProcessor.id -DestinationId $failureLog.id -Relationships @("failure")).id
    }
    Write-Host "已建立五個輸入案例、四條政策分流與 LogAttribute 下游。"

    foreach ($case in $policyCases) {
        Invoke-PolicyCase -Case $case `
            -Context $context `
            -SourceProcessorId $sourceProcessors[$case.Name].id `
            -SourceConnectionId $sourceConnections[$case.Name].id `
            -OutputConnections $outputConnections `
            -PolicyProcessorId $policyProcessor.id
    }

    Write-Host "全部政策驗證成功：五種 JSON 訂單案例均已依預期分流。"
    Write-Host "可在 NiFi UI 開啟 Process Group '$GroupName' 觀察 Processor properties、relationships 與 queue。"
} finally {
    if ($Cleanup -and $context.CreatedGroupId) {
        try {
            Remove-NifiProcessGroup -Context $context -GroupId $context.CreatedGroupId
        } catch {
            Write-Warning "Cleanup 失敗，請在 NiFi UI 手動刪除 Process Group $($context.CreatedGroupId)：$($_.Exception.Message)"
        }
    }
}
