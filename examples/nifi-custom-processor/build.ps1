[CmdletBinding()]
param(
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
$projectDirectory = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$mavenGoals = if ($SkipClean) { @("verify") } else { @("clean", "verify") }

Write-Host "使用 Docker Maven + JDK 21 建置 NiFi 2.9.0 Processor Bundle..."
$dockerArguments = @(
    "run"
    "--rm"
    "--mount"
    "type=bind,source=$projectDirectory,target=/workspace"
    "--mount"
    "type=volume,source=nifi-training-m2,target=/root/.m2"
    "--workdir"
    "/workspace"
    "maven:3.9.14-eclipse-temurin-21"
    "mvn"
    "-B"
) + $mavenGoals

& docker @dockerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Maven verify 失敗，請檢查上方輸出。"
}

$narPath = Join-Path $projectDirectory "nifi-training-custom-processor-nar\target\nifi-training-custom-processor-nar-1.0.0.nar"
if (-not (Test-Path -LiteralPath $narPath)) {
    throw "找不到預期的 NAR 輸出：$narPath"
}

Write-Host "建置完成：$narPath"
