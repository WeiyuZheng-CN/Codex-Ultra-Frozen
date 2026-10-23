[CmdletBinding()]
param([string]$WorkRoot = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$protectTool = Join-Path $sourceRoot 'tools\Protect-FrozenCodex.ps1'
$restoreTool = Join-Path $sourceRoot 'tools\Restore-FrozenCodex.ps1'
$script:checks = 0
if (-not $WorkRoot) {
    $WorkRoot = Join-Path $sourceRoot (
        '..\..\work\frozen-recovery-tests-' + [Guid]::NewGuid().ToString('N'))
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
function Get-RealHash([string]$Path) {
    return (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$install = Join-Path $WorkRoot 'installation'
$appRoot = Join-Path $install 'app'
$profile = Join-Path $WorkRoot 'profile'
$electron = Join-Path $WorkRoot 'electron'
$backupRoot = Join-Path $WorkRoot 'backups'
$desktop = Join-Path $WorkRoot 'desktop'
foreach ($directory in @($install, $appRoot, (Join-Path $appRoot 'resources'),
    $profile, $electron, $backupRoot, $desktop)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$manifest = Join-Path $install 'manifest.json'
$appExe = Join-Path $appRoot 'ChatGPT.exe'
$archive = Join-Path $appRoot 'resources\app.asar'
$originalLauncher = Join-Path $install 'Start-Codex-Ultra-Transfer-Test.ps1'
$originalReadme = Join-Path $install 'README.txt'
$catalog = Join-Path $profile 'models.json'
$configPath = Join-Path $profile 'config.toml'
$desktopLink = Join-Path $desktop 'Codex.lnk'
Write-FixtureText $manifest '{"build":"26.1016.8120.0","global_gate_changed":false}'
Write-FixtureText $appExe 'fixture-executable'
Write-FixtureText $archive 'fixture-archive'
Write-FixtureText $originalLauncher "Write-Output 'original fixture launcher'"
Write-FixtureText $originalReadme 'Original fixture README'
Write-FixtureText $catalog '{"models":[]}'
Write-FixtureText (Join-Path $profile 'auth.json') '{"fixture":true}'
$config = @'
model_provider = "OpenAI"
model = "gpt-fixture"
model_catalog_json = "__CATALOG__"
[model_providers.OpenAI]
base_url = "https://example.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
[desktop]
enabled-reasoning-efforts = ["high", "max", "ultra"]
show-ultra-in-model-picker-slider = true
[features]
multi_agent = true
'@
Write-FixtureText $configPath ($config.Replace('__CATALOG__', $catalog.Replace('\', '\\')))
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($desktopLink)
$link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$link.Arguments = '-NoProfile -Command "exit 0"'
$link.Description = 'Original fixture shortcut'
$link.Save()
$originalHashes = @{
    Launcher = Get-RealHash $originalLauncher
    Readme = Get-RealHash $originalReadme
    Shortcut = Get-RealHash $desktopLink
    Config = Get-RealHash $configPath
}

# Only the reviewed app-identity hash inputs are mocked. These tiny fixture
# files never execute. All ACL operations, file writes, shortcut changes, and
# rollback operations below run against this isolated work directory.
$global:FrozenCodexRecoveryFixtureHashes = @{
    $manifest = '69FCF06FDB7C9FEBAB543787AA66B5685CAA9B3341E4DF56A992534A704CA6A3'
    $appExe = 'CDF5F016626B0BEA2DB507916D19018921E7106D7BDB07622E5C966A9F19954B'
    $archive = '511DD31C365977674456C2EB6E94D3F3746DBC08B4A99AC1343A322D51E17488'
}
function Get-FileHash {
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [string[]]$LiteralPath,
        [string]$Algorithm = 'SHA256'
    )
    $paths = if ($LiteralPath) { $LiteralPath } else { $Path }
    foreach ($entry in $paths) {
        $full = [IO.Path]::GetFullPath($entry)
        if ($global:FrozenCodexRecoveryFixtureHashes.ContainsKey($full)) {
            [pscustomobject]@{ Algorithm = 'SHA256'; Hash = $global:FrozenCodexRecoveryFixtureHashes[$full]; Path = $full }
        }
        else {
            Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $full -Algorithm $Algorithm
        }
    }
}
function Get-AppxPackage {
    param([string]$Name)
    [pscustomobject]@{
        PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
        Version = [version]'26.1016.8622.0'
    }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    return @()
}

$inputs = @{
    InstallRoot = $install
    CodexHome = $profile
    ElectronData = $electron
    BackupRoot = $backupRoot
    DesktopPath = $desktop
}
$result = $null
try {
    $invalid = $inputs.Clone()
    $invalid.BackupRoot = $install
    Assert-Rejected { & $protectTool @invalid -ValidateOnly } 'backup equal to protected root is rejected'
    $invalid = $inputs.Clone()
    $invalid.BackupRoot = Join-Path $install 'backups'
    Assert-Rejected { & $protectTool @invalid -ValidateOnly } 'backup inside protected root is rejected'
    $invalid = $inputs.Clone()
    $invalid.CodexHome = Join-Path $install 'profile'
    Assert-Rejected { & $protectTool @invalid -ValidateOnly } 'profile inside protected root is rejected'
    $invalid = $inputs.Clone()
    $invalid.ElectronData = $install
    Assert-Rejected { & $protectTool @invalid -ValidateOnly } 'Electron data equal to protected root is rejected'
    $preview = & $protectTool @inputs -ValidateOnly
    Assert-Check ($preview.Status -eq 'READY_TO_PROTECT') 'valid fixture inputs preview successfully'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $install 'freeze-plan.json'))) 'preview creates no active plan'
    Assert-Check ((Get-RealHash $originalLauncher) -ceq $originalHashes.Launcher) 'preview preserves launcher bytes'

    $result = & $protectTool @inputs
    Assert-Check ($result.Status -eq 'FROZEN') 'fixture deployment completes'
    Assert-Check (Test-Path -LiteralPath (Join-Path $result.BackupPath 'acl-before.json')) 'ACL recovery data exists'
    Assert-Check (Test-Path -LiteralPath (Join-Path $result.BackupPath 'rollback.json')) 'rollback metadata exists'
    Assert-Rejected { Write-FixtureText $appExe 'blocked write' } 'frozen executable rejects an ordinary write'
    $profileProbe = Join-Path $profile 'write-probe.txt'
    Write-FixtureText $profileProbe 'profile stays writable'
    Assert-Check (Test-Path -LiteralPath $profileProbe) 'private profile remains writable'
    $electronProbe = Join-Path $electron 'write-probe.txt'
    Write-FixtureText $electronProbe 'Electron data stays writable'
    Assert-Check (Test-Path -LiteralPath $electronProbe) 'private Electron data remains writable'
    Assert-Check ((Get-RealHash $configPath) -ceq $originalHashes.Config) 'deployment preserves profile config bytes'
    $activeShortcut = $shell.CreateShortcut($desktopLink)
    Assert-Check ($activeShortcut.Arguments.Contains('Start-FrozenCodex.ps1')) 'fixture shortcut selects frozen launcher'

    $restored = & $restoreTool -BackupPath $result.BackupPath
    Assert-Check ($restored.Status -eq 'RESTORED') 'rollback completes'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $install 'freeze-plan.json'))) 'rollback deactivates active plan'
    Assert-Check (@(Get-ChildItem -LiteralPath $result.BackupPath -Filter 'freeze-plan.deactivated-*.json').Count -eq 1) 'deactivated plan is preserved in backup'
    Assert-Check ((Get-RealHash $originalLauncher) -ceq $originalHashes.Launcher) 'previous launcher is restored'
    Assert-Check ((Get-RealHash $originalReadme) -ceq $originalHashes.Readme) 'previous README is restored'
    Assert-Check ((Get-RealHash $desktopLink) -ceq $originalHashes.Shortcut) 'previous shortcut is restored'
    Write-FixtureText (Join-Path $install 'restore-write-probe.txt') 'permissions restored'
    Assert-Check (Test-Path -LiteralPath (Join-Path $install 'restore-write-probe.txt')) 'restored installation accepts ordinary writes'

    $second = & $protectTool @inputs
    Assert-Check ($second.Status -eq 'FROZEN') 'restored installation can be deliberately deployed again'
    $null = & $restoreTool -BackupPath $second.BackupPath
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $install 'freeze-plan.json'))) 'second rollback deactivates new plan'

    $invalidHistory = $inputs.Clone()
    $invalidHistory.HistoryMigrationPlanPath = Join-Path $WorkRoot 'missing-history-plan.json'
    $invalidHistory.HistoryMigrationReceiptPath = Join-Path $backupRoot 'history-receipt.json'
    $invalidHistory.PythonPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-Rejected { & $protectTool @invalidHistory } 'invalid pending import aborts deployment'
    Assert-Check ((Get-RealHash $originalLauncher) -ceq $originalHashes.Launcher) 'failed deployment preserves or restores previous launcher'
    Assert-Check ((Get-RealHash $desktopLink) -ceq $originalHashes.Shortcut) 'failed deployment preserves or restores previous shortcut'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $install 'freeze-plan.json'))) 'failed deployment leaves no active plan'
    Assert-Check ((Get-RealHash $configPath) -ceq $originalHashes.Config) 'failed deployment leaves profile config intact'
}
catch {
    Write-Warning ('Recovery fixture failed: ' + $_.Exception.Message + "`n" + $_.ScriptStackTrace)
    throw
}
finally {
    # Restore only this generated fixture if a preceding assertion failed.
    # Keep the work files for diagnosis; never recursively delete a test root.
    if (Test-Path -LiteralPath (Join-Path $install 'freeze-plan.json')) {
        $latest = Get-ChildItem -LiteralPath $backupRoot -Directory |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latest -and (Test-Path -LiteralPath (Join-Path $latest.FullName 'rollback.json'))) {
            try { & $restoreTool -BackupPath $latest.FullName | Out-Null }
            catch { Write-Warning ('Fixture rollback also failed: ' + $_.Exception.Message + "`n" + $_.ScriptStackTrace) }
        }
    }
    Remove-Variable -Name FrozenCodexRecoveryFixtureHashes -Scope Global
}

[pscustomobject]@{
    Status = 'OK'
    Checks = $script:checks
    Fixture = $WorkRoot
    RealAppActivated = $false
    ProviderRequest = $false
}
