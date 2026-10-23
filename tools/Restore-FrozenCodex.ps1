[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$BackupPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$BackupPath = [IO.Path]::GetFullPath($BackupPath)
$meta = Get-Content -LiteralPath (Join-Path $BackupPath 'rollback.json') -Raw | ConvertFrom-Json
$root = [IO.Path]::GetFullPath([string]$meta.installRoot).TrimEnd('\')
if ($meta.schemaVersion -ne 1 -or $root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) {
    throw 'Invalid rollback metadata.'
}
$entries = Get-Content -LiteralPath (Join-Path $BackupPath 'acl-before.json') -Raw | ConvertFrom-Json
foreach ($entry in $entries) {
    if ($entry.path -isnot [string] -or $entry.sddl -isnot [string]) {
        throw 'Invalid ACL rollback entry.'
    }
    $p = [IO.Path]::GetFullPath([string]$entry.path)
    if ($p -ne $root -and -not $p.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Rollback target escaped the exact recorded installation.'
    }
}
$sid = New-Object Security.Principal.SecurityIdentifier([string]$meta.userSid)
$ourRights = [Security.AccessControl.FileSystemRights]::Write -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
# First remove only our explicit deny ACE from newly added files, then restore
# every pre-existing security descriptor. No files or profiles are deleted.
foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force) +
    @(Get-Item -LiteralPath $root -Force)) {
    $acl = Get-Acl -LiteralPath $item.FullName
    foreach ($rule in @($acl.Access)) {
        if (-not $rule.IsInherited -and $rule.AccessControlType -eq 'Deny' -and
            $rule.FileSystemRights -eq $ourRights -and
            $rule.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None -and
            $rule.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
            $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid.Value) {
            $acl.RemoveAccessRuleSpecific($rule)
        }
    }
    Set-Acl -LiteralPath $item.FullName -AclObject $acl
}
foreach ($entry in $entries) {
    if (-not (Test-Path -LiteralPath $entry.path)) { continue }
    $acl = Get-Acl -LiteralPath $entry.path
    $acl.SetSecurityDescriptorSddlForm([string]$entry.sddl)
    Set-Acl -LiteralPath $entry.path -AclObject $acl
}
$activePlan = Join-Path $root 'freeze-plan.json'
if (Test-Path -LiteralPath $activePlan) {
    $deactivated = Join-Path $BackupPath ('freeze-plan.deactivated-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
    Move-Item -LiteralPath $activePlan -Destination $deactivated
}
foreach ($name in @('Start-Codex-Ultra-Transfer-Test.ps1', 'README.txt')) {
    $p = Join-Path $BackupPath $name
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $root $name) -Force }
}
$shortcut = Join-Path $BackupPath 'Codex.lnk'
if (Test-Path -LiteralPath $shortcut) {
    Copy-Item -LiteralPath $shortcut -Destination $meta.desktopShortcut -Force
}
elseif ($meta.PSObject.Properties['desktopShortcutExisted'] -and
    -not $meta.desktopShortcutExisted -and (Test-Path -LiteralPath $meta.desktopShortcut)) {
    Move-Item -LiteralPath $meta.desktopShortcut -Destination (Join-Path $BackupPath 'Codex.created-by-freeze.lnk')
}
[pscustomobject]@{ Status = 'RESTORED'; Root = $root; UserDataDeleted = $false; AppStopped = $false }
