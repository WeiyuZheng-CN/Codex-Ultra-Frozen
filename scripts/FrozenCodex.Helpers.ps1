Set-StrictMode -Version 2.0

function Assert-FrozenCodexObjectKeys {
    param($Value, [string[]]$Keys, [string]$Name, [string[]]$OptionalKeys = @())
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Name must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties.Name)
    if (@($Keys | Where-Object { $_ -cnotin $actual }).Count -or
        @($actual | Where-Object { $_ -cnotin ($Keys + $OptionalKeys) }).Count) {
        throw "$Name has missing or unexpected fields."
    }
}

function Assert-FrozenCodexPhysicalPath {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Directory)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '["%\r\n]') {
        throw 'A frozen Codex path must be an absolute local path without command expansion characters.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne [bool]$Directory) {
        throw "Unexpected file or directory type: $full"
    }
    $cursor = $item
    while ($null -ne $cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Filesystem links are not allowed in frozen Codex paths: $($cursor.FullName)"
        }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    return $full.TrimEnd('\', '/')
}

function Get-FrozenCodexAppInventory {
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $root = Assert-FrozenCodexPhysicalPath -Path $AppRoot -Directory
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($root)
    $files = New-Object 'System.Collections.Generic.List[object]'
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Filesystem links are not allowed in the frozen app: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName); continue }
            $relative = $item.FullName.Substring($root.Length + 1).Replace('\', '/')
            $files.Add([pscustomobject][ordered]@{
                path = $relative
                size = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
    }
    return @($files | Sort-Object path)
}

function Get-FrozenCodexTomlSectionRange {
    param([string]$Content, [string]$Section = '')
    $headers = [regex]::Matches($Content, '(?m)^[ \t]*\[[^\r\n]+')
    if (-not $Section) {
        $end = if ($headers.Count) { $headers[0].Index } else { $Content.Length }
        return @{ Start = 0; Length = $end }
    }
    $found = @()
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $header = $headers[$i]
        if ($header.Value -match ('^[ \t]*\[' + [regex]::Escape($Section) + '\][ \t]*(?:#.*)?$')) {
            $start = $header.Index + $header.Length
            $end = if ($i + 1 -lt $headers.Count) { $headers[$i + 1].Index } else { $Content.Length }
            $found += @{ Start = $start; Length = $end - $start }
        }
    }
    if ($found.Count -gt 1) { throw "Duplicate protected TOML section: $Section" }
    if ($found.Count) { return $found[0] }
    return $null
}

function Get-FrozenCodexTomlValue {
    param([string]$Content, [string]$Section = '', [string]$Key)
    $range = Get-FrozenCodexTomlSectionRange -Content $Content -Section $Section
    if ($null -eq $range) { return $null }
    $body = $Content.Substring($range.Start, $range.Length)
    $matches = [regex]::Matches($body, '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*([^\r\n]*)')
    if ($matches.Count -gt 1) { throw "Duplicate protected TOML setting: $Section.$Key" }
    if ($matches.Count) { return $matches[0].Groups[1].Value.Trim() }
    return $null
}

function ConvertTo-FrozenCodexCanonicalToml {
    param([Parameter(Mandatory = $true)][string]$Value)
    # Remove comments/spacing only outside strings; keep quoted whitespace and #.
    $result = New-Object Text.StringBuilder
    $quote = [char]0
    $escaped = $false
    foreach ($character in $Value.ToCharArray()) {
        if ($quote -ne [char]0) {
            [void]$result.Append($character)
            if ($quote -eq '"' -and $escaped) { $escaped = $false; continue }
            if ($quote -eq '"' -and $character -eq '\') { $escaped = $true; continue }
            if ($character -eq $quote) { $quote = [char]0 }
        }
        elseif ($character -eq '#') { break }
        elseif ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            [void]$result.Append($character)
        }
        elseif (-not [char]::IsWhiteSpace($character)) { [void]$result.Append($character) }
    }
    if ($quote -ne [char]0 -or $result.Length -eq 0) { throw 'Unsupported protected TOML value.' }
    return $result.ToString()
}

function Get-FrozenCodexTomlString {
    param([string]$Content, [string]$Section = '', [string]$Key)
    $raw = Get-FrozenCodexTomlValue -Content $Content -Section $Section -Key $Key
    if ($null -eq $raw) { throw "Missing protected TOML string: $Section.$Key" }
    $raw = ConvertTo-FrozenCodexCanonicalToml -Value $raw
    if ($raw -match '^"(?:\\.|[^"\\])*"$') { return ConvertFrom-Json -InputObject $raw }
    if ($raw -match "^'([^']*)'$") { return $Matches[1] }
    throw "Expected a single-line protected TOML string: $Section.$Key"
}

function Get-FrozenCodexTomlBoolean {
    param([string]$Content, [string]$Section, [string]$Key)
    $raw = Get-FrozenCodexTomlValue -Content $Content -Section $Section -Key $Key
    if ($null -eq $raw) { throw "Missing protected TOML boolean: $Section.$Key" }
    $raw = ConvertTo-FrozenCodexCanonicalToml -Value $raw
    if ($raw -ceq 'true') { return $true }
    if ($raw -ceq 'false') { return $false }
    throw "Expected a protected TOML boolean: $Section.$Key"
}

function Get-FrozenCodexFeatures {
    param([string]$Content)
    $features = [ordered]@{}
    $section = ''
    foreach ($line in @($Content -split '\r?\n')) {
        if ($line -match '^\s*\[\[\s*(?:"features"|''features''|features)(?:[.\]\s])') {
            throw 'Arrays of protected feature tables are unsupported.'
        }
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $section = $Matches[1].Trim()
            if (($section -replace '["''\s]', '') -match '^features(?:\.|$)' -and
                $section -notmatch '^features(?:\.[A-Za-z0-9_.-]+)?$') {
                throw 'Quoted protected feature sections are unsupported.'
            }
            continue
        }
        if ($section -eq '' -and
            $line -match '^\s*(?:"features"|''features''|features)\s*(?:\.|=)' -and
            $line -notmatch '^\s*features\.[A-Za-z0-9_.-]+\s*=') {
            throw 'Quoted or inline protected features are unsupported.'
        }
        $topLevelFeature = ($section -eq '' -and $line -match '^\s*features\.')
        if (-not $topLevelFeature -and $section -ne 'features' -and $section -notmatch '^features\.') { continue }
        if ($line -match '^\s*(?:#.*)?$') { continue }
        if ($line -notmatch '^\s*([A-Za-z0-9_.-]+)\s*=\s*(.+)$') {
            throw 'Unsupported syntax in the protected features table.'
        }
        $key = $Matches[1]
        $value = ConvertTo-FrozenCodexCanonicalToml -Value $Matches[2]
        if ($topLevelFeature) { $key = $key.Substring(9) }
        $relativeSection = if ($section -eq 'features' -or $topLevelFeature) { '' } else { $section.Substring(9) + '.' }
        $relativeKey = $relativeSection + $key
        if ($features.Contains($relativeKey)) { throw "Duplicate protected feature: $relativeKey" }
        $features[$relativeKey] = $value
    }
    return [pscustomobject]$features
}

function Get-FrozenCodexConfigBaseline {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $path = Assert-FrozenCodexPhysicalPath -Path $ConfigPath
    $content = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $provider = Get-FrozenCodexTomlString -Content $content -Key model_provider
    if ($provider -notmatch '^[A-Za-z0-9_-]+$') { throw 'Unsupported protected model provider name.' }
    $section = 'model_providers.' + $provider
    $effortsRaw = Get-FrozenCodexTomlValue -Content $content -Section desktop -Key enabled-reasoning-efforts
    if ($null -eq $effortsRaw) { throw 'Missing protected desktop reasoning effort list.' }
    $effortsText = ConvertTo-FrozenCodexCanonicalToml -Value $effortsRaw
    if ($effortsText -notmatch '^\[(?:"[A-Za-z0-9_-]+"(?:,"[A-Za-z0-9_-]+")*,?)?\]$') {
        throw 'Protected desktop reasoning efforts must be a single-line string array.'
    }
    $efforts = @([regex]::Matches($effortsText, '"([A-Za-z0-9_-]+)"') | ForEach-Object { $_.Groups[1].Value })
    if (-not $efforts.Count -or @($efforts | Select-Object -Unique).Count -ne $efforts.Count) {
        throw 'Protected reasoning efforts must be nonempty and unique.'
    }
    return [pscustomobject][ordered]@{
        modelProvider = $provider
        providerSection = $section
        providerBaseUrl = Get-FrozenCodexTomlString -Content $content -Section $section -Key base_url
        providerWireApi = Get-FrozenCodexTomlString -Content $content -Section $section -Key wire_api
        providerRequiresOpenAIAuth = Get-FrozenCodexTomlBoolean -Content $content -Section $section -Key requires_openai_auth
        desktopEnabledReasoningEfforts = @($efforts | Sort-Object)
        desktopShowUltraInModelPickerSlider = Get-FrozenCodexTomlBoolean -Content $content -Section desktop -Key show-ultra-in-model-picker-slider
        features = Get-FrozenCodexFeatures -Content $content
    }
}

function Assert-FrozenCodexConfigBaseline {
    param($Expected, [string]$ConfigPath, [string]$CatalogPath)
    $keys = @('modelProvider', 'providerSection', 'providerBaseUrl', 'providerWireApi',
        'providerRequiresOpenAIAuth', 'desktopEnabledReasoningEfforts',
        'desktopShowUltraInModelPickerSlider', 'features')
    Assert-FrozenCodexObjectKeys -Value $Expected -Keys $keys -Name configBaseline
    if ($Expected.providerRequiresOpenAIAuth -isnot [bool] -or
        $Expected.desktopShowUltraInModelPickerSlider -isnot [bool] -or
        $Expected.desktopEnabledReasoningEfforts -isnot [Array] -or
        $Expected.features -isnot [pscustomobject]) { throw 'Malformed config baseline.' }
    $current = Get-FrozenCodexConfigBaseline -ConfigPath $ConfigPath
    foreach ($key in $keys | Where-Object { $_ -notin @('features', 'desktopEnabledReasoningEfforts') }) {
        if ([string]$current.$key -cne [string]$Expected.$key) { throw "Protected configuration changed: $key" }
    }
    if ((@($current.desktopEnabledReasoningEfforts | Sort-Object) -join ',') -cne
        (@($Expected.desktopEnabledReasoningEfforts | Sort-Object) -join ',')) {
        throw 'Protected desktop reasoning efforts changed.'
    }
    foreach ($property in @($Expected.features.PSObject.Properties)) {
        $actual = $current.features.PSObject.Properties[$property.Name]
        if ($null -eq $actual -or [string]$actual.Value -cne [string]$property.Value) {
            throw "Protected feature changed: $($property.Name)"
        }
    }
    foreach ($property in @($current.features.PSObject.Properties)) {
        if ($null -eq $Expected.features.PSObject.Properties[$property.Name] -and
            $property.Name -match '(?i)multi.?agent|collab') {
            throw "A protected multi-agent feature was added: $($property.Name)"
        }
    }
    $content = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
    $configuredCatalog = Get-FrozenCodexTomlString -Content $content -Key model_catalog_json
    if ([IO.Path]::GetFullPath($configuredCatalog) -ine $CatalogPath) {
        throw 'The protected model catalog path changed.'
    }
}

function Assert-FrozenCodexHash {
    param([string]$Path, [string]$Expected, [string]$Label)
    if ($Expected -notmatch '^[A-Fa-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Expected) {
        throw "$Label is missing or changed."
    }
}

function Assert-FrozenCodexMigrationReceipt {
    param([Parameter(Mandatory = $true)][string]$ReceiptPath)
    if (-not ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type])) {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    }
    $json = [IO.File]::ReadAllText($ReceiptPath, [Text.Encoding]::UTF8)
    try {
        $receipt = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($json)
    }
    catch {
        throw 'History migration receipt contains invalid JSON.'
    }
    if ($receipt -isnot [System.Collections.IDictionary] -or
        -not ($receipt.Keys -ccontains 'status') -or
        $receipt['status'] -isnot [string] -or $receipt['status'] -cne 'COMPLETED') {
        throw 'History migration receipt does not confirm a completed import.'
    }
}

function Read-FrozenCodexPlan {
    param([Parameter(Mandatory = $true)][string]$PlanPath)
    $planFile = Assert-FrozenCodexPhysicalPath -Path $PlanPath
    $plan = Get-Content -LiteralPath $planFile -Raw | ConvertFrom-Json
    Assert-FrozenCodexObjectKeys -Value $plan -Name freeze-plan -Keys @(
        'schemaVersion', 'appRoot', 'build', 'packageFamilyName', 'appManifestPath',
        'appManifestSha256', 'appInventory', 'codexHome', 'electronData', 'configPath',
        'configBaseline', 'catalogPath', 'catalogSha256', 'launchWrapperPath', 'launchWrapperSha256') `
        -OptionalKeys @('historyMigration')
    if ($plan.schemaVersion -ne 1 -or [string]$plan.build -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        [string]$plan.packageFamilyName -notmatch '^[A-Za-z0-9._-]+$' -or
        $plan.appInventory -isnot [Array] -or -not $plan.appInventory.Count) {
        throw 'Unsupported freeze-plan schema or identity.'
    }
    $root = Assert-FrozenCodexPhysicalPath -Path $plan.appRoot -Directory
    $profileHome = Assert-FrozenCodexPhysicalPath -Path $plan.codexHome -Directory
    $electron = Assert-FrozenCodexPhysicalPath -Path $plan.electronData -Directory
    foreach ($key in @('appManifestPath', 'configPath', 'catalogPath', 'launchWrapperPath')) {
        $plan.$key = Assert-FrozenCodexPhysicalPath -Path ([string]$plan.$key)
    }
    if ($plan.configPath -ine (Join-Path $profileHome 'config.toml') -or
        $plan.catalogPath -ine (Join-Path $profileHome 'models.json') -or
        $profileHome.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $electron.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $profileHome -ieq $root -or $electron -ieq $root) {
        throw 'Frozen runtime and writable profile paths overlap or disagree.'
    }
    $plan.appRoot = $root
    $plan.codexHome = $profileHome
    $plan.electronData = $electron
    Assert-FrozenCodexHash -Path $plan.appManifestPath -Expected $plan.appManifestSha256 -Label 'App manifest'
    Assert-FrozenCodexHash -Path $plan.catalogPath -Expected $plan.catalogSha256 -Label 'Model catalog'
    Assert-FrozenCodexHash -Path $plan.launchWrapperPath -Expected $plan.launchWrapperSha256 -Label 'Static launch wrapper'
    $manifest = Get-Content -LiteralPath $plan.appManifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.build -cne [string]$plan.build -or
        $manifest.global_gate_changed -isnot [bool] -or $manifest.global_gate_changed) {
        throw 'The app manifest build or multi-agent patch policy disagrees with the freeze plan.'
    }
    $expected = @{}
    foreach ($entry in $plan.appInventory) {
        Assert-FrozenCodexObjectKeys -Value $entry -Keys @('path', 'size', 'sha256') -Name appInventory-entry
        if ($entry.path -isnot [string] -or $entry.path -match '(^[\\/]|:|\\|//|(^|/)\.\.?(/|$))' -or
            $entry.path -match '[\x00-\x1f]' -or -not $entry.path -or
            $entry.size -isnot [ValueType] -or [decimal]$entry.size -lt 0 -or
            [decimal]$entry.size -ne [math]::Truncate([decimal]$entry.size) -or
            [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $expected.ContainsKey($entry.path)) {
            throw 'Invalid, duplicate, or unsafe frozen app inventory entry.'
        }
        $expected[$entry.path] = $entry
    }
    if (-not $expected.ContainsKey('ChatGPT.exe') -or -not $expected.ContainsKey('resources/app.asar')) {
        throw 'The app inventory lacks the core desktop executable or archive.'
    }
    $actual = @(Get-FrozenCodexAppInventory -AppRoot $root)
    if ($actual.Count -ne $expected.Count) { throw 'The frozen app contains missing or unexpected files.' }
    foreach ($entry in $actual) {
        if (-not $expected.ContainsKey($entry.path) -or
            [long]$expected[$entry.path].size -ne [long]$entry.size -or
            [string]$expected[$entry.path].sha256 -ine [string]$entry.sha256) {
            throw "Frozen app file is unexpected or changed: $($entry.path)"
        }
    }
    Assert-FrozenCodexConfigBaseline -Expected $plan.configBaseline `
        -ConfigPath $plan.configPath -CatalogPath $plan.catalogPath
    if ($plan.PSObject.Properties['historyMigration']) {
        $migration = $plan.historyMigration
        Assert-FrozenCodexObjectKeys -Value $migration -Name historyMigration -Keys @(
            'pythonPath', 'pythonSha256', 'scriptPath', 'scriptSha256',
            'planPath', 'planSha256', 'receiptPath')
        foreach ($key in @('pythonPath', 'scriptPath', 'planPath')) {
            $migration.$key = Assert-FrozenCodexPhysicalPath -Path ([string]$migration.$key)
        }
        foreach ($pair in @(@('pythonPath', 'pythonSha256'), @('scriptPath', 'scriptSha256'), @('planPath', 'planSha256'))) {
            Assert-FrozenCodexHash -Path $migration.($pair[0]) -Expected $migration.($pair[1]) -Label 'History migration dependency'
        }
        $receiptParent = Assert-FrozenCodexPhysicalPath -Path (Split-Path -Parent $migration.receiptPath) -Directory
        if ([IO.Path]::GetFullPath($migration.receiptPath) -ine (Join-Path $receiptParent (Split-Path -Leaf $migration.receiptPath))) {
            throw 'Unsafe history migration receipt path.'
        }
        if (Test-Path -LiteralPath $migration.receiptPath) {
            $null = Assert-FrozenCodexPhysicalPath -Path $migration.receiptPath
            Assert-FrozenCodexMigrationReceipt -ReceiptPath $migration.receiptPath
        }
    }
    return $plan
}

function Get-FrozenCodexPackage {
    param([Parameter(Mandatory = $true)][string]$PackageFamilyName)
    $packages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
        Where-Object { $_.PackageFamilyName -ceq $PackageFamilyName } |
        Sort-Object Version -Descending)
    if (-not $packages.Count) { throw 'The required Codex package family is not installed; no other app will be selected.' }
    return $packages[0]
}

function Get-FrozenCodexDesktopProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop)
}

function Show-FrozenCodexExistingWindow {
    param([Parameter(Mandatory = $true)]$Processes)
    if (-not ('FrozenCodexWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FrozenCodexWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
    }
    $focused = $false
    foreach ($process in @($Processes)) {
        $live = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if ($live -and $live.MainWindowHandle -ne [IntPtr]::Zero) {
            [void][FrozenCodexWindow]::ShowWindowAsync($live.MainWindowHandle, 9)
            $focused = [FrozenCodexWindow]::SetForegroundWindow($live.MainWindowHandle) -or $focused
        }
    }
    return $focused
}
