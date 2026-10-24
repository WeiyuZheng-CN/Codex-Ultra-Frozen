[CmdletBinding()]
param([string]$WorkRoot = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'scripts\FrozenCodex.Helpers.ps1')
$script:checks = 0
if (-not $WorkRoot) {
    $WorkRoot = Join-Path (Split-Path -Parent $sourceRoot) (
        '..\..\work\frozen-codex-tests-' + [Guid]::NewGuid().ToString('N'))
}
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-FixtureText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Check $rejected $Message
}
$app = Join-Path $WorkRoot 'app'
$homePath = Join-Path $WorkRoot 'profile'
$electronPath = Join-Path $WorkRoot 'electron'
foreach ($directory in @($app, (Join-Path $app 'resources'), $homePath, $electronPath)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$config = Join-Path $homePath 'config.toml'
$catalog = Join-Path $homePath 'models.json'
$manifest = Join-Path $WorkRoot 'manifest.json'
$wrapper = Join-Path $WorkRoot 'launch.cmd'
$planFile = Join-Path $WorkRoot 'freeze-plan.json'
Write-FixtureText (Join-Path $app 'ChatGPT.exe') 'fixture-executable'
Write-FixtureText (Join-Path $app 'resources\app.asar') 'fixture-archive'
Write-FixtureText $catalog '{"models":[]}'
Write-FixtureText $manifest '{"build":"26.1016.8120.0","global_gate_changed":false}'
Write-FixtureText $wrapper '@echo off'
$configText = @'
model_provider = "OpenAI"
model = "gpt-fixture"
model_reasoning_effort = "ultra"
model_catalog_json = "__CATALOG__"
[model_providers.OpenAI]
base_url = "https://example.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
[desktop]
enabled-reasoning-efforts = ["low", "high", "max", "ultra"]
show-ultra-in-model-picker-slider = true
[features]
memories = true
multi_agent = true
'@
$configText = $configText.Replace('__CATALOG__', $catalog.Replace('\', '\\'))
Write-FixtureText $config $configText
$plan = [pscustomobject][ordered]@{
    schemaVersion = 1; appRoot = $app; build = '26.1016.8120.0'
    packageFamilyName = 'OpenAI.Codex_fixture'
    appManifestPath = $manifest
    appManifestSha256 = (Get-FileHash $manifest).Hash
    appInventory = @(Get-FrozenCodexAppInventory -AppRoot $app)
    codexHome = $homePath; electronData = $electronPath; configPath = $config
    configBaseline = Get-FrozenCodexConfigBaseline -ConfigPath $config
    catalogPath = $catalog; catalogSha256 = (Get-FileHash $catalog).Hash
    launchWrapperPath = $wrapper; launchWrapperSha256 = (Get-FileHash $wrapper).Hash
}
function Save-FixturePlan {
    Write-FixtureText $planFile ($plan | ConvertTo-Json -Depth 12)
}
Save-FixturePlan
$null = Read-FrozenCodexPlan -PlanPath $planFile
Assert-Check $true 'untouched fixture validates'

$migrationRoot = Join-Path $WorkRoot 'migration'
New-Item -ItemType Directory -Path $migrationRoot -Force | Out-Null
$pythonFixture = Join-Path $migrationRoot 'python.exe'
$scriptFixture = Join-Path $migrationRoot 'Import-CodexHistory.py'
$historyPlanFixture = Join-Path $migrationRoot 'history-plan.json'
$receiptFixture = Join-Path $migrationRoot 'history-receipt.json'
Write-FixtureText $pythonFixture 'fixture-python'
Write-FixtureText $scriptFixture 'fixture-importer'
Write-FixtureText $historyPlanFixture '{}'
$receiptText = @'
{
  "schemaVersion": 1,
  "status": "COMPLETED",
  "providerCounts": {
    "openai": 192,
    "OpenAI": 613
  }
}
'@
Write-FixtureText $receiptFixture $receiptText
$plan | Add-Member -NotePropertyName historyMigration -NotePropertyValue ([pscustomobject][ordered]@{
    pythonPath = $pythonFixture
    pythonSha256 = (Get-FileHash $pythonFixture).Hash
    scriptPath = $scriptFixture
    scriptSha256 = (Get-FileHash $scriptFixture).Hash
    planPath = $historyPlanFixture
    planSha256 = (Get-FileHash $historyPlanFixture).Hash
    receiptPath = $receiptFixture
}) -PassThru | Out-Null
Save-FixturePlan
$null = Read-FrozenCodexPlan -PlanPath $planFile
Assert-Check $true 'completed receipt accepts provider keys differing only by case'
Write-FixtureText $receiptFixture ($receiptText.Replace('"COMPLETED"', '"PREPARED"'))
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'incomplete migration receipt is rejected'
Write-FixtureText $receiptFixture $receiptText
$plan.PSObject.Properties.Remove('historyMigration')
Save-FixturePlan

Write-FixtureText (Join-Path $app 'resources\app.asar') 'altered'
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'archive tampering rejected'
Write-FixtureText (Join-Path $app 'resources\app.asar') 'fixture-archive'
Write-FixtureText (Join-Path $app 'unexpected.txt') 'extra'
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'unexpected app file rejected'
Remove-Item -LiteralPath (Join-Path $app 'unexpected.txt')
$originalPath = $plan.appInventory[0].path
$plan.appInventory[0].path = '../outside.exe'
Save-FixturePlan
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'inventory traversal rejected'
$plan.appInventory[0].path = $originalPath
Save-FixturePlan

Write-FixtureText $config ($configText.Replace('multi_agent = true', 'multi_agent = false'))
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'baseline multi-agent drift rejected'
Write-FixtureText $config ($configText.Replace('[features]', "[features]`ncollab = true"))
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'new collab switch rejected'
Write-FixtureText $config ("features.collab = true`n" + $configText)
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'top-level dotted collab switch rejected'
Write-FixtureText $config ($configText.Replace('https://example.invalid/v1', 'https://other.invalid/v1'))
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'provider endpoint drift rejected'
Write-FixtureText $config ($configText.Replace('"low", "high", "max", "ultra"', '"low", "high", "max"'))
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'reasoning effort loss rejected'
Write-FixtureText $config ($configText.Replace('show-ultra-in-model-picker-slider = true',
    'show-ultra-in-model-picker-slider = false'))
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'Ultra preference loss rejected'
$allowed = $configText.Replace('model = "gpt-fixture"', 'model = "gpt-another"').
    Replace('model_reasoning_effort = "ultra"', 'model_reasoning_effort = "high"') +
    "`n[plugins.fixture]`nenabled = true`n"
Write-FixtureText $config $allowed
$null = Read-FrozenCodexPlan -PlanPath $planFile
Assert-Check $true 'model/reasoning choices and plugin additions remain allowed'
Write-FixtureText $config ($configText.Replace('base_url =', 'base_url =').Replace(
    'wire_api = "responses"', "wire_api = 'responses' # harmless formatting"))
$null = Read-FrozenCodexPlan -PlanPath $planFile
Assert-Check $true 'critical string comment/quote formatting is semantic'
Write-FixtureText $config $configText

$global:FrozenCodexTestFamily = 'OpenAI.Codex_fixture'
$global:FrozenCodexTestActivationCalls = 0
$global:FrozenCodexTestProcesses = @()
$global:FrozenCodexTestActivationArgs = ''
function Get-AppxPackage {
    param([string]$Name)
    [pscustomobject]@{ PackageFamilyName = $global:FrozenCodexTestFamily; Version = [version]'26.1016.8622.0' }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    return $global:FrozenCodexTestProcesses
}
function Invoke-CommandInDesktopPackage {
    param($PackageFamilyName, $AppId, $Command, [Alias('Args')]$LaunchArguments, [switch]$PreventBreakaway)
    $global:FrozenCodexTestActivationCalls++
    $global:FrozenCodexTestActivationArgs = [string]$LaunchArguments
}
$before = @(Get-ChildItem -LiteralPath $WorkRoot -Recurse -Force -File |
    ForEach-Object { $_.FullName + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks + ':' + (Get-FileHash $_.FullName).Hash })
$result = & (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -PlanPath $planFile -ValidateOnly
$after = @(Get-ChildItem -LiteralPath $WorkRoot -Recurse -Force -File |
    ForEach-Object { $_.FullName + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks + ':' + (Get-FileHash $_.FullName).Hash })
Assert-Check ($result.Status -eq 'VALIDATED' -and $result.CrossVersion) 'matching family permits frozen cross-version validation'
Assert-Check (($before -join "`n") -ceq ($after -join "`n")) 'ValidateOnly leaves fixture bytes and timestamps unchanged'
Assert-Check ($global:FrozenCodexTestActivationCalls -eq 0) 'ValidateOnly never activates an app'
$global:FrozenCodexTestFamily = 'Other.Package_fixture'
Assert-Rejected {
    & (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -PlanPath $planFile -ValidateOnly
} 'another package family is rejected'
$global:FrozenCodexTestFamily = 'OpenAI.Codex_fixture'
Write-FixtureText (Join-Path $app 'ChatGPT.exe') 'modified'
Assert-Rejected {
    & (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -PlanPath $planFile -ValidateOnly
} 'changed app fails closed without an official fallback'
Assert-Check ($global:FrozenCodexTestActivationCalls -eq 0) 'all rejection cases leave activation unused'
Write-FixtureText (Join-Path $app 'ChatGPT.exe') 'fixture-executable'
$global:FrozenCodexTestProcesses = @([pscustomobject]@{
    ProcessId = 2147483647; ExecutablePath = (Join-Path $app 'ChatGPT.exe')
})
$runningResult = & (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -PlanPath $planFile
Assert-Check ($runningResult.Status -eq 'ALREADY_RUNNING') 'an existing frozen app is reused'
Assert-Check ($global:FrozenCodexTestActivationCalls -eq 0) 'existing-instance path never activates a duplicate'
$global:FrozenCodexTestProcesses = @()
$launchedResult = & (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -PlanPath $planFile
Assert-Check ($launchedResult.Status -eq 'LAUNCH_DISPATCHED' -and
    $global:FrozenCodexTestActivationCalls -eq 1) 'closed-app route requests exactly one package activation'
Assert-Check ($global:FrozenCodexTestActivationArgs.Contains((Join-Path $app 'ChatGPT.exe')) -and
    -not $global:FrozenCodexTestActivationArgs.Contains('WindowsApps')) 'activation uses only the frozen executable'

$junction = Join-Path $app 'linked-directory'
New-Item -ItemType Junction -Path $junction -Target $homePath | Out-Null
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'linked directory in app is rejected'
# Delete the link itself; never recurse through its target.
[IO.Directory]::Delete($junction)
$unknown = $plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$unknown | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
Write-FixtureText $planFile ($unknown | ConvertTo-Json -Depth 12)
Assert-Rejected { Read-FrozenCodexPlan -PlanPath $planFile } 'unknown plan fields are rejected'
Save-FixturePlan

# Use the same fresh-process -File entry point as a Windows shortcut, omitting
# -PlanPath. PSScriptRoot is not available while PS5.1 binds default parameters.
$childRoot = Join-Path $WorkRoot 'child-launcher'
New-Item -ItemType Directory -Path $childRoot -Force | Out-Null
$childLauncher = Join-Path $childRoot 'Start-FrozenCodex.ps1'
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -Destination $childLauncher
Copy-Item -LiteralPath $planFile -Destination (Join-Path $childRoot 'freeze-plan.json')
$childHelper = [IO.File]::ReadAllText((Join-Path $sourceRoot 'scripts\FrozenCodex.Helpers.ps1'))
$childMocks = @'

function Get-FrozenCodexPackage {
    param([string]$PackageFamilyName)
    [pscustomobject]@{ PackageFamilyName = 'OpenAI.Codex_fixture'; Version = [version]'26.1016.8622.0' }
}
function Get-FrozenCodexDesktopProcesses { return @() }
function Invoke-CommandInDesktopPackage { throw 'A validation-only child must not activate an app.' }
'@
Write-FixtureText (Join-Path $childRoot 'FrozenCodex.Helpers.ps1') ($childHelper + $childMocks)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$childOutput = (& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass `
    -File $childLauncher -ValidateOnly | Out-String -Width 4096)
Assert-Check ($LASTEXITCODE -eq 0 -and $childOutput -match '\bVALIDATED\b') `
    'fresh PS5.1 -File startup finds the default adjacent plan'

Remove-Variable -Name FrozenCodexTestFamily, FrozenCodexTestActivationCalls,
    FrozenCodexTestProcesses, FrozenCodexTestActivationArgs -Scope Global
[pscustomobject]@{ Status = 'OK'; Checks = $script:checks; Fixture = $WorkRoot }
