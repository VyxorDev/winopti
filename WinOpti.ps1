# WinOpti v1.0 - one-file, reversible Windows 11 gaming optimizer
# Repository: https://github.com/VyxorDev/winopti
#
# Usage (PowerShell 5.1 or 7, same normal Windows user account):
#   .\WinOpti.ps1 -Mode Status                # no elevation required
#   .\WinOpti.ps1 -Mode Apply                 # run PowerShell as Administrator
#   .\WinOpti.ps1 -Mode Undo                  # run PowerShell as Administrator
#
# Default mode is Status. Backups are saved under %LOCALAPPDATA%\WinOpti.
# No third-party dependencies, downloads, persistence, or auto-elevation.
# Deliberately does NOT disable Defender, Windows Update, drivers, services,
# startup programs, anti-cheat, HP OMEN firmware/fans/MUX, or delete files.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Apply', 'Undo')]
    [string]$Mode = 'Status'
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'WinOpti only supports Windows 11.'
}
if ([Environment]::OSVersion.Version.Major -lt 10 -or
    [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'WinOpti requires Windows 11 (build 22000 or later).'
}

$script:identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:userSid = $script:identity.User.Value
$script:store = Join-Path $env:LOCALAPPDATA 'WinOpti'
$script:stateFile = Join-Path $script:store 'baseline.clixml'
$script:previousFile = Join-Path $script:store 'baseline.previous.clixml'
$script:logFile = Join-Path $script:store 'operations.log'
$script:state = $null

# These settings match the conservative, tested OMEN Auto Performance script.
$script:settings = @(
    [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 1; Kind = 'DWord'; Label = 'Game Mode ON' },
    [pscustomobject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0; Kind = 'DWord'; Label = 'Background game DVR OFF' },
    [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0; Kind = 'DWord'; Label = 'Game capture OFF' },
    [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 0; Kind = 'DWord'; Label = 'Transparency OFF' },
    [pscustomobject]@{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Value = '0'; Kind = 'String'; Label = 'Window minimize animations OFF' }
)
$script:bestPerformance = 'ded574b5-45a0-4f42-8737-46345c09c238'

function Write-Log([string]$Message) {
    $entry = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Write-Host $Message
    try { Add-Content -LiteralPath $script:logFile -Value $entry -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Warning ('Could not write log: ' + $_.Exception.Message) }
}

function Get-RegistrySnapshot([string]$Path, [string]$Name) {
    $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.GetValueNames() -contains $Name)) {
        return [pscustomobject]@{
            Existed = $true
            Value = $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = $item.GetValueKind($Name).ToString()
        }
    }
    return [pscustomobject]@{ Existed = $false; Value = $null; Kind = $null }
}

function Test-SnapshotMatches($Snapshot, [bool]$Existed, $Value, [string]$Kind) {
    if ([bool]$Snapshot.Existed -ne $Existed) { return $false }
    if (-not $Existed) { return $true }
    return (([string]$Snapshot.Value -ceq [string]$Value) -and
            ([string]$Snapshot.Kind -ceq [string]$Kind))
}

function Save-State {
    if ($null -eq $script:state) { throw 'No backup state available.' }
    # Write a complete temporary backup, then atomically replace the previous one.
    $tempPath = Join-Path $script:store ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $script:state | Export-Clixml -LiteralPath $tempPath -Encoding UTF8
        if (Test-Path -LiteralPath $script:stateFile) {
            [System.IO.File]::Replace($tempPath, $script:stateFile, $script:previousFile)
        } else {
            [System.IO.File]::Move($tempPath, $script:stateFile)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:stateFile)) { return }
    $script:state = Import-Clixml -LiteralPath $script:stateFile
    if ($null -eq $script:state -or $script:state.Version -ne 1) {
        throw 'Unrecognized WinOpti backup format. No changes were made.'
    }
    if ($script:state.UserSid -ne $script:userSid) {
        throw 'Backup belongs to a different Windows account. No changes were made.'
    }
}

function Ensure-State {
    if ($null -ne $script:state) { return }
    $script:state = [pscustomobject]@{
        Version = 1
        UserSid = $script:userSid
        CreatedAt = (Get-Date).ToString('o')
        Registry = @()
        ACMode = $null
    }
    Save-State
}

function Initialize-PowerApi {
    if ('WinOptiPowerApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinOptiPowerApi {
    [StructLayout(LayoutKind.Sequential)]
    public struct SystemPowerStatus {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
    [DllImport("powrprof.dll", ExactSpelling = true)]
    public static extern uint PowerGetUserConfiguredACPowerMode(out Guid powerMode);
    [DllImport("powrprof.dll", ExactSpelling = true)]
    public static extern uint PowerSetUserConfiguredACPowerMode(ref Guid powerMode);
}
'@
}

function Get-ACPowerInfo {
    Initialize-PowerApi
    $status = New-Object WinOptiPowerApi+SystemPowerStatus
    if (-not [WinOptiPowerApi]::GetSystemPowerStatus([ref]$status)) {
        throw 'Cannot detect whether AC power is connected.'
    }
    $guid = [guid]::Empty
    $rc = [WinOptiPowerApi]::PowerGetUserConfiguredACPowerMode([ref]$guid)
    if ($rc -ne 0) { throw ('Windows AC power-mode API returned error ' + $rc) }
    return [pscustomobject]@{
        Connected = ($status.ACLineStatus -eq 1)
        Mode = $guid.ToString()
    }
}

function Set-ACPowerMode([string]$ModeGuid) {
    $guid = [guid]::Parse($ModeGuid)
    $rc = [WinOptiPowerApi]::PowerSetUserConfiguredACPowerMode([ref]$guid)
    if ($rc -ne 0) { throw ('Cannot set AC power mode; Windows error ' + $rc) }
}

function Show-Status {
    Write-Log '=== WINOPTI | STATUS ==='
    foreach ($setting in $script:settings) {
        $current = Get-RegistrySnapshot $setting.Path $setting.Name
        $optimized = Test-SnapshotMatches $current $true $setting.Value $setting.Kind
        $status = if ($optimized) { 'OPTIMIZED' } else { 'NOT OPTIMIZED' }
        Write-Log ('{0}: {1}' -f $status, $setting.Label)
    }
    try {
        $power = Get-ACPowerInfo
        $ac = if ($power.Connected) { 'connected' } else { 'battery / AC unknown' }
        $perf = if ($power.Mode -eq $script:bestPerformance) { 'Best performance' } else { 'other / balanced / efficiency' }
        Write-Log ('AC: {0}; Windows AC mode: {1} ({2})' -f $ac, $perf, $power.Mode)
    } catch { Write-Log ('AC power-mode status unavailable: ' + $_.Exception.Message) }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $used = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
        $free = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        Write-Log ('RAM snapshot: used {0} GiB, available {1} GiB' -f $used, $free)
    } catch { Write-Log ('RAM status unavailable: ' + $_.Exception.Message) }
    if ($null -ne $script:state) {
        $pendingPower = if ($null -ne $script:state.ACMode) { 1 } else { 0 }
        Write-Log ('Undo backup: {0} ({1} registry settings, {2} AC mode)' -f
            $script:stateFile, @($script:state.Registry).Count, $pendingPower)
    } else {
        Write-Log 'No active WinOpti undo backup (settings may have been changed by another script).'
    }
}

function Invoke-Apply {
    Write-Log '=== WINOPTI | APPLY ==='
    foreach ($setting in $script:settings) {
        try {
            $current = Get-RegistrySnapshot $setting.Path $setting.Name
            if (Test-SnapshotMatches $current $true $setting.Value $setting.Kind) {
                Write-Log ('ALREADY SET: ' + $setting.Label)
                continue
            }
            Ensure-State
            $recorded = @($script:state.Registry | Where-Object {
                $_.Path -eq $setting.Path -and $_.Name -eq $setting.Name
            }).Count -gt 0
            if (-not $recorded) {
                $script:state.Registry += [pscustomobject]@{
                    Path = $setting.Path
                    Name = $setting.Name
                    Existed = $current.Existed
                    OldValue = $current.Value
                    OldKind = $current.Kind
                    ExpectedValue = $setting.Value
                    ExpectedKind = $setting.Kind
                }
                Save-State # Baseline is durable BEFORE the registry write.
            }
            New-Item -Path $setting.Path -Force | Out-Null
            New-ItemProperty -Path $setting.Path -Name $setting.Name -Value $setting.Value -PropertyType $setting.Kind -Force | Out-Null
            Write-Log ('APPLIED: ' + $setting.Label)
        } catch { Write-Log ('SKIPPED {0}: {1}' -f $setting.Name, $_.Exception.Message) }
    }
    try {
        $power = Get-ACPowerInfo
        if (-not $power.Connected) {
            Write-Log 'POWER SKIPPED: Plug in your charger and rerun Apply.'
        } elseif ($power.Mode -eq $script:bestPerformance) {
            Write-Log 'POWER ALREADY SET: Windows AC Best performance.'
        } else {
            Ensure-State
            if ($null -eq $script:state.ACMode) {
                $script:state.ACMode = [pscustomobject]@{
                    OldValue = $power.Mode
                    ExpectedValue = $script:bestPerformance
                }
                Save-State # Baseline is durable BEFORE the AC mode write.
            }
            Set-ACPowerMode $script:bestPerformance
            Write-Log 'POWER APPLIED: Windows AC Best performance (battery/DC mode untouched).'
        }
    } catch { Write-Log ('POWER SKIPPED: ' + $_.Exception.Message) }
    if ($null -ne $script:state) {
        Write-Log ('Undo backup: ' + $script:stateFile)
    } else {
        Write-Log 'No new settings needed changing; no backup was created.'
    }
    Write-Log 'Finished. Sign out or restart if visual changes do not appear.'
    Write-Log 'No guaranteed FPS uplift; performance varies by system and game.'
}

function Invoke-Undo {
    Write-Log '=== WINOPTI | UNDO ==='
    if ($null -eq $script:state) {
        Write-Log 'No active WinOpti backup to restore. Older OMEN backups are separate.'
        return
    }
    $remaining = @()
    foreach ($record in @($script:state.Registry)) {
        try {
            $current = Get-RegistrySnapshot $record.Path $record.Name
            $isWinOptiValue = Test-SnapshotMatches $current $true $record.ExpectedValue $record.ExpectedKind
            $isOriginal = Test-SnapshotMatches $current ([bool]$record.Existed) $record.OldValue $record.OldKind
            if ($isOriginal) {
                Write-Log ('ALREADY RESTORED: ' + $record.Name)
            } elseif (-not $isWinOptiValue) {
                Write-Log ('PRESERVED MANUAL CHANGE: ' + $record.Name)
                $remaining += $record
            } else {
                if ($record.Existed) {
                    New-Item -Path $record.Path -Force | Out-Null
                    New-ItemProperty -Path $record.Path -Name $record.Name -Value $record.OldValue -PropertyType $record.OldKind -Force | Out-Null
                } else {
                    Remove-ItemProperty -Path $record.Path -Name $record.Name -ErrorAction Stop
                }
                Write-Log ('RESTORED: ' + $record.Name)
            }
        } catch {
            Write-Log ('RESTORE FAILED {0}: {1}' -f $record.Name, $_.Exception.Message)
            $remaining += $record
        }
    }
    $script:state.Registry = @($remaining)
    Save-State

    if ($null -ne $script:state.ACMode) {
        try {
            $power = Get-ACPowerInfo
            if ($power.Mode -eq $script:state.ACMode.OldValue) {
                Write-Log 'AC power mode already restored.'
                $script:state.ACMode = $null
                Save-State
            } elseif ($power.Mode -ne $script:state.ACMode.ExpectedValue) {
                Write-Log 'Preserved manual AC power-mode change.'
            } else {
                Set-ACPowerMode $script:state.ACMode.OldValue
                Write-Log 'RESTORED: Previous Windows AC power mode.'
                $script:state.ACMode = $null
                Save-State
            }
        } catch { Write-Log ('AC power-mode restore failed: ' + $_.Exception.Message) }
    }
    if (@($script:state.Registry).Count -eq 0 -and $null -eq $script:state.ACMode) {
        $archive = Join-Path $script:store ('restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.clixml')
        Move-Item -LiteralPath $script:stateFile -Destination $archive -ErrorAction Stop
        $script:state = $null
        Write-Log ('Undo complete. Archived original baseline: ' + $archive)
    } else {
        Write-Log ('Partial undo. Remaining entries kept in backup: ' + $script:stateFile)
    }
    Write-Log 'Sign out or restart if visual settings have not refreshed.'
}

# Reading Status is safe without administrator rights; Apply/Undo require elevation.
if ($Mode -ne 'Status') {
    $principal = [Security.Principal.WindowsPrincipal]$script:identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell as Administrator using your normal Windows account, then rerun.'
    }
}

New-Item -ItemType Directory -Path $script:store -Force | Out-Null
Load-State
switch ($Mode) {
    'Status' { Show-Status }
    'Apply' { Invoke-Apply }
    'Undo' { Invoke-Undo }
}
