[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$ElectronData,
    [Parameter(Mandatory = $true)][string]$BackupRoot,
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
    [string]$ShortcutIconPath = '',
    [string]$HistoryMigrationPlanPath,
    [string]$HistoryMigrationReceiptPath,
    [string]$PythonPath,
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'scripts\FrozenCodex.Helpers.ps1')

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$ElectronData = [IO.Path]::GetFullPath($ElectronData).TrimEnd('\')
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
$DesktopPath = Assert-FrozenCodexPhysicalPath -Path $DesktopPath -Directory
$shortcutIconSource = ''
if ($ShortcutIconPath) {
    $shortcutIconSource = Assert-FrozenCodexPhysicalPath -Path ([IO.Path]::GetFullPath($ShortcutIconPath))
    if ([IO.Path]::GetExtension($shortcutIconSource) -ine '.ico' -or
        (Get-Item -LiteralPath $shortcutIconSource).Length -gt 2MB) {
        throw 'ShortcutIconPath must be an ICO file no larger than 2 MiB.'
    }
}
$backupAncestor = $BackupRoot
while (-not (Test-Path -LiteralPath $backupAncestor)) {
    $backupAncestor = Split-Path -Parent $backupAncestor
    if (-not $backupAncestor) { throw 'A backup target needs an existing local ancestor.' }
}
$null = Assert-FrozenCodexPhysicalPath -Path $backupAncestor -Directory
foreach ($target in @($InstallRoot, $CodexHome, $ElectronData, $BackupRoot)) {
    if ($target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\') -or
        $target -eq $env:USERPROFILE.TrimEnd('\')) {
        throw 'An installation, profile or backup target cannot be a drive or user root.'
    }
}
if ($BackupRoot -ieq $InstallRoot -or
    $BackupRoot.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ACL recovery data must stay outside the protected installation.'
}
foreach ($profileDirectory in @($CodexHome, $ElectronData)) {
    if ($profileDirectory -ieq $InstallRoot -or
        $profileDirectory.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Writable profiles must stay outside the entire protected installation.'
    }
}
if ($HistoryMigrationPlanPath) {
    if (-not $PythonPath -or -not $HistoryMigrationReceiptPath) {
        throw 'A pending history import requires the exact Python and receipt paths.'
    }
    $PythonPath = Assert-FrozenCodexPhysicalPath -Path $PythonPath
    $HistoryMigrationPlanPath = Assert-FrozenCodexPhysicalPath -Path $HistoryMigrationPlanPath
    $null = Assert-FrozenCodexPhysicalPath -Path (Join-Path $sourceRoot 'tools\Import-CodexHistory.py')
    $receiptFull = [IO.Path]::GetFullPath($HistoryMigrationReceiptPath)
    if ($receiptFull -ieq $InstallRoot -or
        $receiptFull.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The history receipt must stay outside the protected installation.'
    }
    $null = Assert-FrozenCodexPhysicalPath -Path (Split-Path -Parent $receiptFull) -Directory
}
$appRoot = Join-Path $InstallRoot 'app'
$manifestPath = Join-Path $InstallRoot 'manifest.json'
$expected = @{
    'app\ChatGPT.exe' = 'CDF5F016626B0BEA2DB507916D19018921E7106D7BDB07622E5C966A9F19954B'
    'app\resources\app.asar' = '511DD31C365977674456C2EB6E94D3F3746DBC08B4A99AC1343A322D51E17488'
}
foreach ($entry in $expected.GetEnumerator()) {
    $path = Join-Path $InstallRoot $entry.Key
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.Value) {
        throw "The reviewed build does not match: $($entry.Key)"
    }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.build -cne '26.1016.8120.0' -or
    $manifest.global_gate_changed -isnot [bool] -or $manifest.global_gate_changed -or
    [string]$manifest.patched_exe_sha256 -ine $expected['app\ChatGPT.exe'] -or
    [string]$manifest.patched_asar_sha256 -ine $expected['app\resources\app.asar'] -or
    $manifest.changes -isnot [Array] -or $manifest.changes.Count -ne 2 -or
    $manifest.changes[0] -cne 'picker query includeUltra flag only' -or
    $manifest.changes[1] -cne 'disable Codex in-app update checks and automatic downloads') {
    throw 'The app manifest build, reviewed patch set, or multi-agent patch policy disagrees.'
}
foreach ($path in @($appRoot, $CodexHome, $ElectronData)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "An existing runtime/profile directory is required: $path"
    }
    $null = Assert-FrozenCodexPhysicalPath -Path $path -Directory
}
foreach ($path in @((Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1'),
    (Join-Path $sourceRoot 'scripts\FrozenCodex.Helpers.ps1'),
    (Join-Path $CodexHome 'config.toml'), (Join-Path $CodexHome 'models.json'),
    (Join-Path $CodexHome 'auth.json'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing file: $path" }
}
$null = Get-FrozenCodexConfigBaseline -ConfigPath (Join-Path $CodexHome 'config.toml')
$links = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
if ($links.Count) { throw 'The existing installation contains a filesystem link.' }

if ($shortcutIconSource) {
    $installedShortcutIcon = Join-Path $InstallRoot 'shortcut-icon.ico'
    if ((Test-Path -LiteralPath $installedShortcutIcon -PathType Leaf) -and
        (Get-FileHash -LiteralPath $installedShortcutIcon -Algorithm SHA256).Hash -ine
            (Get-FileHash -LiteralPath $shortcutIconSource -Algorithm SHA256).Hash) {
        throw 'An installed shortcut icon already exists with different content.'
    }
}

if ($ValidateOnly) {
    [pscustomobject]@{
        Status = 'READY_TO_PROTECT'
        AppBuild = '26.1016.8120.0'
        InstallRoot = $InstallRoot
        Profile = $CodexHome
        WritesPerformed = $false
        ProviderRequest = $false
    }
    return
}
if (Test-Path -LiteralPath (Join-Path $InstallRoot 'freeze-plan.json')) {
    throw 'A freeze plan already exists. Use its saved rollback instructions before redeploying.'
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backup = Join-Path $BackupRoot ('freeze-' + $stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$null = Assert-FrozenCodexPhysicalPath -Path $backup -Directory
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value

# Save security descriptors before applying any restriction. These contain no
# credentials or conversation data and remain outside the public repository.
$before = @()
foreach ($item in @(Get-Item -LiteralPath $InstallRoot -Force) +
    @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force)) {
    $before += [pscustomobject]@{
        path = $item.FullName
        sddl = (Get-Acl -LiteralPath $item.FullName).Sddl
        attributes = [int]$item.Attributes
    }
}
[IO.File]::WriteAllText((Join-Path $backup 'acl-before.json'),
    (ConvertTo-Json -InputObject $before -Depth 5), (New-Object Text.UTF8Encoding($false)))
foreach ($name in @('Start-Codex-Ultra-Transfer-Test.ps1', 'README.txt')) {
    $path = Join-Path $InstallRoot $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup }
}
$desktopShortcut = Join-Path $DesktopPath 'Codex.lnk'
$hadDesktopShortcut = Test-Path -LiteralPath $desktopShortcut
if (Test-Path -LiteralPath $desktopShortcut) {
    Copy-Item -LiteralPath $desktopShortcut -Destination (Join-Path $backup 'Codex.lnk')
}
$meta = [ordered]@{
    schemaVersion = 1
    installRoot = $InstallRoot
    backupPath = $backup
    userSid = $sid
    desktopShortcut = $desktopShortcut
    desktopShortcutExisted = [bool]$hadDesktopShortcut
    newFiles = @('Start-FrozenCodex.ps1', 'FrozenCodex.Helpers.ps1', 'Start-FrozenCodex-WindowRestore.ps1',
        'freeze-plan.json', 'launch\run-frozen.cmd', 'LOCAL-CHANGES.md', 'Import-CodexHistory.py', 'shortcut-icon.ico')
}
[IO.File]::WriteAllText((Join-Path $backup 'rollback.json'),
    ($meta | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
try {
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\Start-FrozenCodex.ps1') -Destination $InstallRoot
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\FrozenCodex.Helpers.ps1') -Destination $InstallRoot
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\Start-FrozenCodex-WindowRestore.ps1') -Destination $InstallRoot
$launcher = Join-Path $InstallRoot 'Start-FrozenCodex.ps1'
if ($shortcutIconSource -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'shortcut-icon.ico'))) {
    Copy-Item -LiteralPath $shortcutIconSource -Destination (Join-Path $InstallRoot 'shortcut-icon.ico')
}
$compatibility = @'
[CmdletBinding()]
param([switch]$ValidateOnly)
& (Join-Path $PSScriptRoot 'Start-FrozenCodex.ps1') @PSBoundParameters
'@
[IO.File]::WriteAllText((Join-Path $InstallRoot 'Start-Codex-Ultra-Transfer-Test.ps1'),
    $compatibility, (New-Object Text.UTF8Encoding($false)))
$launchRoot = Join-Path $InstallRoot 'launch'
New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
$wrapper = Join-Path $launchRoot 'run-frozen.cmd'
$wrapperLines = @('@echo off', 'set "CODEX_HOME=%~1"',
    'set "CODEX_ELECTRON_USER_DATA_PATH=%~2"',
    'start "" /b "%~3" "--user-data-dir=%~2"', '')
[IO.File]::WriteAllText($wrapper, ($wrapperLines -join "`r`n"), [Text.Encoding]::ASCII)

$inventory = @(Get-ChildItem -LiteralPath $appRoot -Recurse -File -Force |
    Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($appRoot.Length + 1).Replace('\', '/')
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
$configPath = Join-Path $CodexHome 'config.toml'
$catalogPath = Join-Path $CodexHome 'models.json'
$plan = [ordered]@{
    schemaVersion = 1
    appRoot = $appRoot
    build = '26.1016.8120.0'
    packageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
    appManifestPath = $manifestPath
    appManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    appInventory = $inventory
    codexHome = $CodexHome
    electronData = $ElectronData
    configPath = $configPath
    configBaseline = Get-FrozenCodexConfigBaseline -ConfigPath $configPath
    catalogPath = $catalogPath
    catalogSha256 = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    launchWrapperPath = $wrapper
    launchWrapperSha256 = (Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash.ToLowerInvariant()
}
if ($HistoryMigrationPlanPath) {
    if (-not $PythonPath -or -not $HistoryMigrationReceiptPath) {
        throw 'A pending history import requires the exact Python and receipt paths.'
    }
    $historySource = Join-Path $sourceRoot 'tools\Import-CodexHistory.py'
    $historyScript = Join-Path $InstallRoot 'Import-CodexHistory.py'
    Copy-Item -LiteralPath $historySource -Destination $historyScript
    $plan['historyMigration'] = [ordered]@{
        pythonPath = [IO.Path]::GetFullPath($PythonPath)
        pythonSha256 = (Get-FileHash -LiteralPath $PythonPath -Algorithm SHA256).Hash.ToLowerInvariant()
        scriptPath = $historyScript
        scriptSha256 = (Get-FileHash -LiteralPath $historyScript -Algorithm SHA256).Hash.ToLowerInvariant()
        planPath = [IO.Path]::GetFullPath($HistoryMigrationPlanPath)
        planSha256 = (Get-FileHash -LiteralPath $HistoryMigrationPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
        receiptPath = [IO.Path]::GetFullPath($HistoryMigrationReceiptPath)
    }
}
$planPath = Join-Path $InstallRoot 'freeze-plan.json'
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 12),
    (New-Object Text.UTF8Encoding($false)))

$readme = @"
Codex Ultra Frozen - build 26.1016.8120.0

This is the default copied app, using the existing modified Transfer profile.
The normal Store app remains installed for Windows package identity but is not
selected by this launcher. A version/hash/config mismatch stops startup; it
never silently switches to another app or rewrites the guarded settings.

App files are protected against ordinary writes/deletion for Windows user $sid.
An administrator can deliberately change permissions; this is a reversible
local freeze, not protection against a hostile administrator or remote services.
Only in-app updates are disabled. Store updates can change the separate package
identity dependency, and remote rollout/provider behavior is outside this freeze.

Profiles and Electron data remain writable. They are outside the protected app.
Keep credentials, chat history and backups private. Do not put this folder in Git.

Backup and ACL rollback data:
$backup

Use tools/Restore-FrozenCodex.ps1 -BackupPath "<that directory>" to restore saved
ACLs and the previous launcher/desktop shortcut. This does not delete user data.
"@
[IO.File]::WriteAllText((Join-Path $InstallRoot 'README.txt'), $readme,
    (New-Object Text.UTF8Encoding($false)))

$changes = @"
# Local freeze - $stamp

User requested that the currently running modified copy become the default.
Pinned all $($inventory.Count) app files, retained the two reviewed binary
changes, and guarded the current provider/catalog/Ultra feature settings.
No running process, profile config, authentication, database or history changed.
Profiles remain writable; altered guarded settings cause refusal, not repair.
The desktop Codex shortcut points to Start-FrozenCodex-WindowRestore.ps1, which delegates to the pinned launcher and restores its Electron window if activation leaves it hidden. The normal Store app remains unused as a runtime. No fallback or model refresh is performed.

Recoverable backup: $backup
Checks performed after deployment are recorded in the private task report.
"@
[IO.File]::WriteAllText((Join-Path $InstallRoot 'LOCAL-CHANGES.md'), $changes,
    (New-Object Text.UTF8Encoding($false)))

# The deny ACE covers ordinary writes and deletion even if the user is also
# an Administrator. WRITE_DAC is retained for an explicit, backed-up rollback.
$denyRights = [Security.AccessControl.FileSystemRights]::Write -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
$user = New-Object Security.Principal.SecurityIdentifier($sid)
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
    $user, $denyRights, [Security.AccessControl.InheritanceFlags]::None,
    [Security.AccessControl.PropagationFlags]::None,
    [Security.AccessControl.AccessControlType]::Deny)
$protectedItems = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force) +
    @(Get-Item -LiteralPath $InstallRoot -Force)
foreach ($item in $protectedItems) {
    $acl = Get-Acl -LiteralPath $item.FullName
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $item.FullName -AclObject $acl
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($desktopShortcut)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$windowLauncher = Join-Path $InstallRoot 'Start-FrozenCodex-WindowRestore.ps1'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $windowLauncher + '"'
$shortcut.WorkingDirectory = $InstallRoot
$shortcut.IconLocation = if ($shortcutIconSource) {
    (Join-Path $InstallRoot 'shortcut-icon.ico') + ',0'
} else {
    (Join-Path $appRoot 'resources\icon-chatgpt.ico') + ',0'
}
$shortcut.Description = 'Open the frozen Codex Ultra Transfer app and existing modified profile.'
$shortcut.Save()
$result = & $launcher -ValidateOnly
[pscustomobject]@{
    Status = 'FROZEN'
    Build = $plan.build
    ApplicationFiles = $inventory.Count
    InstallRoot = $InstallRoot
    BackupPath = $backup
    DesktopShortcut = $desktopShortcut
    Validation = $result
    RealAppLaunch = $false
    ProviderRequest = $false
}
}
catch {
    $cause = $_
    try { & (Join-Path $PSScriptRoot 'Restore-FrozenCodex.ps1') -BackupPath $backup | Out-Null }
    catch { Write-Warning ('Automatic rollback needs attention; backup: ' + $backup) }
    throw $cause
}
