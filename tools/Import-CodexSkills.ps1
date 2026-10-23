[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$SourceHomes,
    [Parameter(Mandatory = $true)][string]$TargetHome,
    [Parameter(Mandatory = $true)][string]$BackupRoot,
    [switch]$ValidateOnly
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$TargetHome = [IO.Path]::GetFullPath($TargetHome)
$skillsRoot = Join-Path $TargetHome 'skills'
if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
    throw 'An existing target skills directory is required.'
}
$candidates = @()
$seen = @{}
foreach ($skillSourceHome in $SourceHomes) {
    $source = Join-Path ([IO.Path]::GetFullPath($skillSourceHome)) 'skills'
    if (-not (Test-Path -LiteralPath $source)) { continue }
    foreach ($directory in Get-ChildItem -LiteralPath $source -Directory -Force) {
        if ($directory.Name.StartsWith('.') -or
            -not (Test-Path -LiteralPath (Join-Path $directory.FullName 'SKILL.md') -PathType Leaf)) { continue }
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Skill links require separate review.' }
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw 'A source skill contains a filesystem link.'
        }
        $destination = Join-Path $skillsRoot $directory.Name
        if ((Test-Path -LiteralPath $destination) -or $seen.ContainsKey($directory.Name)) { continue }
        $seen[$directory.Name] = $true
        $candidates += [pscustomobject]@{
            name = $directory.Name
            source = $directory.FullName
            destination = $destination
        }
    }
}
if ($ValidateOnly) {
    [pscustomobject]@{ Status = 'PLAN'; Skills = $candidates; WritesPerformed = $false }
    return
}
$backup = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) ('skills-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$results = @()
foreach ($candidate in $candidates) {
    $stage = Join-Path $TargetHome ('skill-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $stageSkill = Join-Path $stage $candidate.name
    Copy-Item -LiteralPath $candidate.source -Destination $stageSkill -Recurse
    $before = @(Get-ChildItem -LiteralPath $candidate.source -File -Recurse -Force)
    $after = @(Get-ChildItem -LiteralPath $stageSkill -File -Recurse -Force)
    if ($before.Count -ne $after.Count) { throw "Skill copy count changed: $($candidate.name)" }
    foreach ($file in $before) {
        $relative = $file.FullName.Substring($candidate.source.Length + 1)
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne
            (Get-FileHash -LiteralPath (Join-Path $stageSkill $relative)).Hash) {
            throw "Skill file changed during copy: $($candidate.name)"
        }
    }
    # Publishing a complete new directory is atomic on this volume. Existing
    # skills are never replaced, and .system is never copied.
    [IO.Directory]::Move($stageSkill, $candidate.destination)
    [IO.Directory]::Delete($stage, $false)
    $results += [pscustomobject]@{ name = $candidate.name; files = $before.Count;
        source = $candidate.source; destination = $candidate.destination }
}
$record = [ordered]@{ created = (Get-Date).ToUniversalTime().ToString('o');
    targetHome = $TargetHome; imported = $results; existingSkillsOverwritten = $false;
    rollback = 'Remove only the named imported directories after closing Codex; originals remain at the source.' }
[IO.File]::WriteAllText((Join-Path $backup 'skills-import.json'), ($record | ConvertTo-Json -Depth 6),
    (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ Status = 'IMPORTED'; Skills = @($results).Count; Files = ($results | Measure-Object files -Sum).Sum;
    Names = @($results | ForEach-Object name); Receipt = (Join-Path $backup 'skills-import.json');
    SystemSkillsChanged = $false; HistoryChanged = $false }
