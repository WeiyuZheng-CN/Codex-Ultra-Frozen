[CmdletBinding()]
param([string]$WorkRoot = $env:TEMP)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('frozen-acl-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$file = Join-Path $fixture 'asset.txt'
[IO.File]::WriteAllText($file, 'approved asset')
$original = @{}
foreach ($p in @($fixture, $file)) { $original[$p] = (Get-Acl -LiteralPath $p).Sddl }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$rights = [Security.AccessControl.FileSystemRights]::Write -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
    $sid, $rights, [Security.AccessControl.InheritanceFlags]::None,
    [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Deny)
$checks = 0
try {
    foreach ($p in @($file, $fixture)) {
        $acl = Get-Acl -LiteralPath $p
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $p -AclObject $acl
    }
    $writeBlocked = $false
    try { [IO.File]::AppendAllText($file, 'unexpected change') }
    catch [UnauthorizedAccessException] { $writeBlocked = $true }
    if (-not $writeBlocked) { throw 'The freeze did not block file writes.' }
    $checks++
    $createBlocked = $false
    try { [IO.File]::WriteAllText((Join-Path $fixture 'injected.txt'), 'unexpected') }
    catch [UnauthorizedAccessException] { $createBlocked = $true }
    if (-not $createBlocked) { throw 'The freeze did not block directory injection.' }
    $checks++
    if ([IO.File]::ReadAllText($file) -cne 'approved asset') { throw 'Protected file changed.' }
    $checks++
}
finally {
    foreach ($p in @($fixture, $file)) {
        $acl = Get-Acl -LiteralPath $p
        $acl.SetSecurityDescriptorSddlForm($original[$p])
        Set-Acl -LiteralPath $p -AclObject $acl
    }
}
[IO.File]::AppendAllText($file, ' restored')
if ([IO.File]::ReadAllText($file) -cne 'approved asset restored') { throw 'ACL rollback failed.' }
$checks++
[pscustomobject]@{ Status = 'OK'; Checks = $checks; Fixture = $fixture; LiveInstallationChanged = $false }
