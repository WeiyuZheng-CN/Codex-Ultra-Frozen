[CmdletBinding()]
param(
    [string]$PlanPath = (Join-Path $PSScriptRoot 'freeze-plan.json'),
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FrozenCodex.Helpers.ps1')
$startupMutex = $null
$ownsStartupMutex = $false

try {
    if (-not $ValidateOnly) {
        $startupMutex = New-Object Threading.Mutex($false, 'Local\CodexUltraFrozenStartup')
        try { $ownsStartupMutex = $startupMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsStartupMutex = $true }
        if (-not $ownsStartupMutex) { throw 'Frozen Codex is already preparing to start. Wait for that launch to finish.' }
    }
    $plan = Read-FrozenCodexPlan -PlanPath $PlanPath
    $package = Get-FrozenCodexPackage -PackageFamilyName $plan.packageFamilyName
    $app = Join-Path $plan.appRoot 'ChatGPT.exe'
    $desktopProcesses = @(Get-FrozenCodexDesktopProcesses)
    $other = @($desktopProcesses | Where-Object {
        -not $_.ExecutablePath -or $_.ExecutablePath -ine $app
    })
    $same = @($desktopProcesses | Where-Object { $_.ExecutablePath -ieq $app })
    if ($ValidateOnly) {
        [pscustomobject][ordered]@{
            Status = 'VALIDATED'
            RuntimeKind = 'Frozen'
            AppBuild = $plan.build
            InstalledPackageBuild = [string]$package.Version
            CrossVersion = ([string]$package.Version -cne [string]$plan.build)
            InventoryFiles = $plan.appInventory.Count
            CriticalConfiguration = 'MatchesBaseline'
            ExistingFrozenProcesses = $same.Count
            OtherCodexProcesses = $other.Count
            LaunchAllowed = ($other.Count -eq 0)
            HistoryMigration = if ($plan.PSObject.Properties['historyMigration']) {
                if (Test-Path -LiteralPath $plan.historyMigration.receiptPath) { 'Completed' } else { 'PendingUntilCodexClosed' }
            } else { 'NotConfigured' }
            FilesChanged = $false
            AppLaunched = $false
            ProviderRequest = $false
        }
        return
    }
    if ($other.Count) {
        throw 'Another Codex runtime is open. Close it normally before starting Frozen Codex; no running process was stopped.'
    }
    if ($same.Count) {
        $focused = Show-FrozenCodexExistingWindow -Processes $same
        [pscustomobject]@{
            Status = 'ALREADY_RUNNING'; RuntimeKind = 'Frozen'
            WindowFocused = [bool]$focused; AppLaunched = $false; ProviderRequest = $false
        }
        return
    }
    if (-not (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) {
        throw 'Windows package activation is unavailable; Frozen Codex was not launched.'
    }
    if ($plan.PSObject.Properties['historyMigration'] -and
        -not (Test-Path -LiteralPath $plan.historyMigration.receiptPath)) {
        $migration = $plan.historyMigration
        $migrationWindow = $null
        try {
            Add-Type -AssemblyName PresentationFramework
            $migrationWindow = New-Object Windows.Window
            $migrationWindow.Title = 'Frozen Codex'
            $migrationWindow.Width = 470
            $migrationWindow.Height = 150
            $migrationWindow.ResizeMode = 'NoResize'
            $migrationWindow.WindowStartupLocation = 'CenterScreen'
            $migrationWindow.WindowStyle = 'ToolWindow'
            $migrationText = New-Object Windows.Controls.TextBlock
            $migrationText.Text = 'Importing your previous conversations. Keep Codex closed until this finishes.'
            $migrationText.TextWrapping = 'Wrap'
            $migrationText.Margin = '24'
            $migrationText.FontSize = 16
            $migrationWindow.Content = $migrationText
            $migrationWindow.Show()
            [void]$migrationWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
            & $migration.pythonPath -B $migration.scriptPath --plan $migration.planPath | Out-Null
        }
        finally {
            if ($null -ne $migrationWindow) { $migrationWindow.Close() }
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $migration.receiptPath)) {
            throw 'History import did not complete. Frozen Codex was not launched; existing data remains available.'
        }
        # Revalidate the imported profile and the completion receipt before launch.
        $plan = Read-FrozenCodexPlan -PlanPath $PlanPath
    }
    # An app may have opened while validation or the import was running.
    if (@(Get-FrozenCodexDesktopProcesses).Count) {
        throw 'Codex opened while the launcher was preparing. No duplicate app or provider switch was started.'
    }
    # The wrapper is created and hashed at installation. Startup never rewrites it.
    $arguments = '/d /v:off /c ""' + $plan.launchWrapperPath + '" "' +
        $plan.codexHome + '" "' + $plan.electronData + '" "' + $app + '""'
    Invoke-CommandInDesktopPackage -PackageFamilyName $plan.packageFamilyName -AppId App `
        -Command (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Args $arguments -PreventBreakaway | Out-Null
    [pscustomobject][ordered]@{
        Status = 'LAUNCH_DISPATCHED'
        RuntimeKind = 'Frozen'
        AppBuild = $plan.build
        InstalledPackageBuild = [string]$package.Version
        CrossVersion = ([string]$package.Version -cne [string]$plan.build)
        AppLaunched = 'PackageActivationRequested'
        WindowVerified = $false
        ProviderRequest = $false
    }
}
catch {
    if ($ValidateOnly) { throw }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Frozen Codex')
    }
    catch { Write-Error 'Frozen Codex could not start. Run with -ValidateOnly for the validation error.' }
    exit 1
}
finally {
    if ($ownsStartupMutex -and $null -ne $startupMutex) { $startupMutex.ReleaseMutex() }
    if ($null -ne $startupMutex) { $startupMutex.Dispose() }
}
