[CmdletBinding()]
param(
    [string]$PlanPath = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    $PlanPath = Join-Path $PSScriptRoot 'freeze-plan.json'
}
$utilityManifest = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
Import-Module -Name $utilityManifest -ErrorAction Stop
$launcher = Join-Path $PSScriptRoot 'Start-FrozenCodex.ps1'
$arguments = @{ PlanPath = $PlanPath }
if ($ValidateOnly) { $arguments.ValidateOnly = $true }
$result = & $launcher @arguments
if ($ValidateOnly -or $null -eq $result -or
    [string]$result.Status -notin @('LAUNCH_DISPATCHED', 'ALREADY_RUNNING')) {
    return $result
}

if (-not ('FrozenCodexWindowRestorer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class FrozenCodexWindowRestorer {
    private delegate bool EnumWindowsProc(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr handle, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr handle, StringBuilder text, int count);
    public static IntPtr FindElectronWindow(int targetProcessId) {
        IntPtr candidate = IntPtr.Zero;
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            uint processId; GetWindowThreadProcessId(handle, out processId);
            if (processId != (uint)targetProcessId) return true;
            var className = new StringBuilder(256);
            GetClassName(handle, className, className.Capacity);
            if (className.ToString() != "Chrome_WidgetWin_0") return true;
            candidate = handle;
            return !IsWindowVisible(handle);
        }, IntPtr.Zero);
        return candidate;
    }
    public static bool RestoreAndFocus(IntPtr handle) {
        ShowWindowAsync(handle, 9);
        return SetForegroundWindow(handle);
    }
    public static bool IsVisible(IntPtr handle) { return IsWindowVisible(handle); }
}
'@
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$app = Join-Path ([string]$plan.appRoot) 'ChatGPT.exe'
$deadline = [DateTime]::UtcNow.AddSeconds(20)
$visible = $false
do {
    $instances = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -ieq $app })
    foreach ($instance in $instances) {
        $process = Get-Process -Id $instance.ProcessId -ErrorAction SilentlyContinue
        $handle = if ($process -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
            $process.MainWindowHandle
        } else {
            [FrozenCodexWindowRestorer]::FindElectronWindow([int]$instance.ProcessId)
        }
        if ($handle -eq [IntPtr]::Zero) { continue }
        [void][FrozenCodexWindowRestorer]::RestoreAndFocus($handle)
        if ([FrozenCodexWindowRestorer]::IsVisible($handle)) { $visible = $true; break }
    }
    if ($visible) { break }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $visible) {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    [void][System.Windows.MessageBox]::Show(
        'Frozen Codex started, but its window could not be restored. The process was left running.',
        'Frozen Codex')
}
return $result
