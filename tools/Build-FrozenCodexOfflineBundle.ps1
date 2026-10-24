[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$OutputArchive,
    [string]$ShortcutIconPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'scripts\FrozenCodex.Helpers.ps1')

$InstallRoot = Assert-FrozenCodexPhysicalPath -Path ([IO.Path]::GetFullPath($InstallRoot)) -Directory
$appRoot = Join-Path $InstallRoot 'app'
$manifestPath = Join-Path $InstallRoot 'manifest.json'
$expectedExe = 'CDF5F016626B0BEA2DB507916D19018921E7106D7BDB07622E5C966A9F19954B'
$expectedAsar = '511DD31C365977674456C2EB6E94D3F3746DBC08B4A99AC1343A322D51E17488'
$exePath = Join-Path $appRoot 'ChatGPT.exe'
$asarPath = Join-Path $appRoot 'resources\app.asar'
foreach ($path in @($manifestPath, $exePath, $asarPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing reviewed bundle input: $path" }
}
if ((Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash -ine $expectedExe -or
    (Get-FileHash -LiteralPath $asarPath -Algorithm SHA256).Hash -ine $expectedAsar) {
    throw 'The app executable/archive do not match the reviewed frozen build.'
}
$originalManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$originalManifest.build -cne '26.1016.8120.0' -or
    $originalManifest.global_gate_changed -isnot [bool] -or $originalManifest.global_gate_changed -or
    [string]$originalManifest.patched_exe_sha256 -ine $expectedExe -or
    [string]$originalManifest.patched_asar_sha256 -ine $expectedAsar -or
    $originalManifest.changes -isnot [Array] -or $originalManifest.changes.Count -ne 2 -or
    $originalManifest.changes[0] -cne 'picker query includeUltra flag only' -or
    $originalManifest.changes[1] -cne 'disable Codex in-app update checks and automatic downloads') {
    throw 'The local manifest is not the reviewed patch set.'
}

$inventory = @(Get-FrozenCodexAppInventory -AppRoot $appRoot)
if ($inventory.Count -ne 3627 -or
    @($inventory | Where-Object { $_.path -ceq 'ChatGPT.exe' -and $_.sha256 -ieq $expectedExe }).Count -ne 1 -or
    @($inventory | Where-Object { $_.path -ceq 'resources/app.asar' -and $_.sha256 -ieq $expectedAsar }).Count -ne 1) {
    throw 'Frozen application inventory does not match the reviewed payload.'
}
$applicationBytes = [long](($inventory | Measure-Object -Property size -Sum).Sum)

$OutputArchive = [IO.Path]::GetFullPath($OutputArchive)
if ([IO.Path]::GetExtension($OutputArchive) -ine '.zip') { throw 'OutputArchive must end with .zip.' }
if (Test-Path -LiteralPath $OutputArchive) { throw 'Output archive already exists; choose a new destination.' }
$outputParent = Split-Path -Parent $OutputArchive
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'Output archive parent directory must already exist.' }
$outputParent = Assert-FrozenCodexPhysicalPath -Path $outputParent -Directory
if ($OutputArchive.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $OutputArchive.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The offline bundle must be outside the source repository and frozen installation.'
}
$drive = [IO.Path]::GetPathRoot($OutputArchive)
$freeBytes = (Get-PSDrive -Name $drive.TrimEnd('\').TrimEnd(':') -ErrorAction Stop).Free
if ($freeBytes -lt 5GB) { throw 'At least 5 GiB free space is required for a verified bundle build.' }

if ($ShortcutIconPath) {
    $ShortcutIconPath = Assert-FrozenCodexPhysicalPath -Path ([IO.Path]::GetFullPath($ShortcutIconPath))
    if ([IO.Path]::GetExtension($ShortcutIconPath) -ine '.ico' -or
        (Get-Item -LiteralPath $ShortcutIconPath).Length -gt 2MB) {
        throw 'ShortcutIconPath must be an ICO file no larger than 2 MiB.'
    }
}

$stage = Join-Path $env:TEMP ('codex-ultra-offline-stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$stage = [IO.Path]::GetFullPath($stage)
try {
    $stagedApp = Join-Path $stage 'app'
    Copy-Item -LiteralPath $appRoot -Destination $stagedApp -Recurse
    $copiedInventory = @(Get-FrozenCodexAppInventory -AppRoot $stagedApp)
    if ($copiedInventory.Count -ne $inventory.Count) { throw 'Copied app file count differs from the source inventory.' }
    for ($i = 0; $i -lt $inventory.Count; $i++) {
        if ($copiedInventory[$i].path -cne $inventory[$i].path -or
            [long]$copiedInventory[$i].size -ne [long]$inventory[$i].size -or
            $copiedInventory[$i].sha256 -ine $inventory[$i].sha256) {
            throw "Copied app file differs from the reviewed source: $($inventory[$i].path)"
        }
    }

    $portableManifest = [ordered]@{
        schemaVersion = 1
        build = '26.1016.8120.0'
        global_gate_changed = $false
        patched_exe_sha256 = $expectedExe.ToLowerInvariant()
        patched_asar_sha256 = $expectedAsar.ToLowerInvariant()
        changes = @(
            'picker query includeUltra flag only',
            'disable Codex in-app update checks and automatic downloads'
        )
        signature_notice = 'Modified local copy; vendor signature no longer validates.'
    }
    [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'),
        ($portableManifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    $sourceFiles = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @('.gitattributes', '.gitignore', 'AGENTS.md', 'NOTICE.md', 'README.md')) {
        $path = Join-Path $sourceRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $sourceFiles.Add($path) }
    }
    foreach ($directoryName in @('docs', 'scripts', 'tests', 'tools')) {
        $directory = Join-Path $sourceRoot $directoryName
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force)) {
            if ($file.Extension -in @('.md', '.ps1', '.py') -and $file.Name -ine 'LOCAL-CHANGES.md') {
                $sourceFiles.Add($file.FullName)
            }
        }
    }
    foreach ($file in $sourceFiles) {
        $relative = $file.Substring($sourceRoot.Length + 1)
        if ($relative -match '(^|[\\/])\.git([\\/]|$)|(^|[\\/])(LOCAL-CHANGES\.md|freeze-plan\.json|auth\.json|config\.toml|models\.json|.*\.sqlite(?:3)?(?:-.*)?|.*\.jsonl)$') {
            throw "Private or generated source path refused: $relative"
        }
        $destination = Join-Path $stage $relative
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $file -Destination $destination
    }

    if ($ShortcutIconPath) {
        $assets = Join-Path $stage 'assets'
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
        Copy-Item -LiteralPath $ShortcutIconPath -Destination (Join-Path $assets 'shortcut-icon.ico')
    }

    $setup = @'
# Codex Ultra Frozen - private offline bundle

This package contains the reviewed modified Codex build 26.1016.8120.0 and the source launcher/deployment tools. It is intended for the owner's personal use on another Windows computer. Do not publish or redistribute it unless the relevant software rights permit that use.

The package excludes this computer's freeze plan, source/profile configuration, authentication, conversation history, databases, Electron data, backups, logs, and user-specific absolute paths. Each destination needs a fresh local deployment plan, profile inputs, and backup root.

Destination-side prerequisite: the Windows OpenAI.Codex package family (OpenAI.Codex_2p2nqsd0c76g0) must be installed for package activation. This bundle does not contain an MSIX/AppX package or Windows Store signing material. Do not bypass Windows security or package identity checks. Destination setup should be performed by its local maintenance agent using tools/Protect-FrozenCodex.ps1 after placing app/ and this manifest.json into a new InstallRoot and preparing the destination's profile folders/configuration.

Pixel Transfer is a remote provider and requires network connectivity for requests. Packaging Codex does not make provider inference available offline.

The modified executable/archive are not vendor-signed. The local manifest and bundle inventory pin the reviewed bytes; they do not make the copy an official vendor release.
'@
    [IO.File]::WriteAllText((Join-Path $stage 'OFFLINE-SETUP.md'), $setup, (New-Object Text.UTF8Encoding($false)))

    $bundleFiles = @(
        Get-ChildItem -LiteralPath $stage -Recurse -File -Force |
            ForEach-Object {
                $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
                [pscustomobject][ordered]@{
                    path = $relative
                    size = [long]$_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            } | Sort-Object path
    )
    $bundleManifest = [ordered]@{
        schemaVersion = 1
        build = '26.1016.8120.0'
        packageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
        global_gate_changed = $false
        applicationFileCount = $inventory.Count
        applicationBytes = $applicationBytes
        applicationInventory = $inventory
        bundleFileCountExcludingManifest = $bundleFiles.Count
        files = $bundleFiles
    }
    [IO.File]::WriteAllText((Join-Path $stage 'bundle-manifest.json'),
        ($bundleManifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stage, $OutputArchive, [IO.Compression.CompressionLevel]::Optimal, $false)

    $archive = [IO.Compression.ZipFile]::OpenRead($OutputArchive)
    try {
        $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($entries.Count -ne ($bundleFiles.Count + 1)) {
            throw 'Archive entry count does not match the generated inventory.'
        }
        $expectedPaths = @{}
        foreach ($file in $bundleFiles) {
            $relative = ([string]$file.path).Replace('\', '/')
            if ($expectedPaths.ContainsKey($relative)) { throw "Duplicate bundle path: $relative" }
            $expectedPaths[$relative] = $true
        }
        $expectedPaths['bundle-manifest.json'] = $true
        foreach ($entry in $entries) {
            $relative = $entry.FullName.Replace('\', '/')
            if (-not $expectedPaths.ContainsKey($relative)) {
                throw "Archive contains an unexpected or duplicate path: $relative"
            }
            [void]$expectedPaths.Remove($relative)
            if ($relative -match '(?i)(^|/)(freeze-plan(?:\..*)?\.json|auth\.json|config\.toml|config\.yml|LOCAL-CHANGES\.md|sessions|archived_sessions|electron-data|backups|profiles)(/|$)|C:/Users/') {
                throw "Archive contains a private or machine-specific path: $relative"
            }
        }
        if ($expectedPaths.Count) { throw 'Archive is missing one or more inventory paths.' }
        $expectedByPath = @{}
        foreach ($file in $bundleFiles) { $expectedByPath[$file.path] = $file }
        $embeddedManifest = $null
        foreach ($entry in $entries) {
            $stream = $entry.Open()
            try {
                if ($entry.FullName -ceq 'bundle-manifest.json') {
                    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
                    try { $embeddedManifest = $reader.ReadToEnd() }
                    finally { $reader.Dispose() }
                    continue
                }
                $relative = $entry.FullName.Replace('\', '/')
                if (-not $expectedByPath.ContainsKey($relative)) { throw "Unexpected ZIP entry: $relative" }
                $digest = [Security.Cryptography.SHA256]::Create()
                try { $hashBytes = $digest.ComputeHash($stream) }
                finally { $digest.Dispose() }
                $hash = [BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
                $expectedFile = $expectedByPath[$relative]
                if ([long]$entry.Length -ne [long]$expectedFile.size -or $hash -ine [string]$expectedFile.sha256) {
                    throw "Archived file failed size/hash verification: $relative"
                }
            }
            finally { $stream.Dispose() }
        }
        if (-not $embeddedManifest) { throw 'The ZIP lacks its bundle-manifest.json.' }
        $parsedBundleManifest = $embeddedManifest | ConvertFrom-Json
        if ($parsedBundleManifest.schemaVersion -ne 1 -or
            [string]$parsedBundleManifest.build -cne '26.1016.8120.0' -or
            $parsedBundleManifest.global_gate_changed -isnot [bool] -or $parsedBundleManifest.global_gate_changed -or
            $parsedBundleManifest.files -isnot [Array] -or
            $parsedBundleManifest.files.Count -ne $bundleFiles.Count) {
            throw 'The embedded bundle manifest is malformed or disagrees with the reviewed build.'
        }
        $embeddedFiles = @($parsedBundleManifest.files | Sort-Object path)
        for ($i = 0; $i -lt $bundleFiles.Count; $i++) {
            if ($embeddedFiles[$i].path -cne $bundleFiles[$i].path -or
                [long]$embeddedFiles[$i].size -ne [long]$bundleFiles[$i].size -or
                [string]$embeddedFiles[$i].sha256 -ine [string]$bundleFiles[$i].sha256) {
                throw "Embedded bundle inventory mismatch: $($bundleFiles[$i].path)"
            }
        }
    }
    finally { $archive.Dispose() }

    $result = [pscustomobject][ordered]@{
        Status = 'BUNDLE_VERIFIED'
        Build = '26.1016.8120.0'
        ApplicationFiles = $inventory.Count
        ApplicationBytes = $applicationBytes
        Archive = $OutputArchive
        ArchiveBytes = (Get-Item -LiteralPath $OutputArchive).Length
        ContainsMachineFreezePlan = $false
        ContainsProfileOrCredentials = $false
        ContainsWindowsPackageInstaller = $false
        ProviderRequests = $false
    }
    $result
}
finally {
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($stage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $stage) -match '^codex-ultra-offline-stage-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
