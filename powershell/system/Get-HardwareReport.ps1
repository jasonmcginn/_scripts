<#
.SYNOPSIS
    Writes a plain-text hardware and tooling report for this Windows machine.

.DESCRIPTION
    Collects OS, CPU, RAM, GPU (with VRAM from nvidia-smi when present), physical
    disks, volumes, and the state of WSL, Docker and Ollama. Tools that are missing
    or not running are reported as such instead of failing. Output is UTF-8 text,
    saved as <FileNamePrefix>-<date>.txt in OutputFolder.

.PARAMETER OutputFolder
    Folder the report is saved to. Created if missing.

.PARAMETER FileNamePrefix
    Start of the report file name.

.PARAMETER DateFormat
    Date format used in the file name.

.PARAMETER LineWidth
    Width used when formatting tables in the report.

.PARAMETER ShowReport
    Also print the report to the console.

.EXAMPLE
    .\Get-HardwareReport.ps1
    .\Get-HardwareReport.ps1 -OutputFolder 'D:\Reports' -ShowReport

.NOTES
    Version:     1.1.0
    Status:      draft
    Changes:     writes-files
    Requires:    Windows 10 or 11, Windows PowerShell 5.1 or PowerShell 7
    Author:      Jason R. McGinn
    Created:     2026-10-25
    Updated:     2026-10-25
    LastTested:  never
    Deployed:    none
    History:     Replaces ps_HardwareOutput_Win1X.ps1, whose output mixed text
                 encodings (wsl writes UTF-16) and errored on missing tools.
#>
[CmdletBinding()]
param(
    # ================= SETTINGS: change these, or pass them on the command line =================
    [string]$OutputFolder = [Environment]::GetFolderPath('MyDocuments'),
    [string]$FileNamePrefix = 'hardware',
    [string]$DateFormat = 'yyyy-MM-dd',
    [int]$LineWidth = 200,
    [switch]$ShowReport
    # ============================================================================================
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$sb = New-Object System.Text.StringBuilder
function Add-Section([string]$Title, $Body) {
    [void]$sb.AppendLine("== $Title ==")
    [void]$sb.AppendLine((($Body | Out-String -Width $LineWidth).TrimEnd()))
    [void]$sb.AppendLine('')
}
function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    # Runs a native tool and returns its text, or a plain status if it is missing or fails.
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return "$Name : not installed (not found on PATH)" }
    $ErrorActionPreference = 'Continue'   # native tools write to stderr; don't let that stop the script
    $global:LASTEXITCODE = 0
    try {
        $out = & $Name @Arguments 2>&1 | ForEach-Object { "$_" }
        $text = (($out -join [Environment]::NewLine) -replace "`0", '').Trim()
        if ($LASTEXITCODE -ne 0) { return "$Name : returned exit code $LASTEXITCODE`n$text" }
        return $text
    } catch {
        return "$Name : failed ($($_.Exception.Message))"
    }
}

# --- OS, CPU, RAM
$os = Get-CimInstance Win32_OperatingSystem
Add-Section 'Operating system' ([pscustomobject]@{
    Caption = $os.Caption; Version = $os.Version; Build = $os.BuildNumber
    RAM_GB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
} | Format-List)

Add-Section 'CPU' (Get-CimInstance Win32_Processor | Format-List Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)

# --- GPU
Add-Section 'GPU (Windows)' (Get-CimInstance Win32_VideoController | Format-List Name, DriverVersion)
# Windows reports adapter memory capped at 4 GB, so ask nvidia-smi for the real VRAM when it exists.
Add-Section 'GPU (nvidia-smi)' (Invoke-Tool 'nvidia-smi' @('--query-gpu=name,memory.total,driver_version', '--format=csv'))

# --- Storage
Add-Section 'Physical disks' (Get-PhysicalDisk | Format-Table FriendlyName, MediaType, @{n = 'GB'; e = { [math]::Round($_.Size / 1GB) } } -AutoSize)
Add-Section 'Volumes' (Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter |
    Format-Table DriveLetter, FileSystemLabel, @{n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB) } }, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } } -AutoSize)

# --- Tooling
$env:WSL_UTF8 = '1'   # ask wsl for UTF-8 instead of UTF-16 output
Add-Section 'WSL' (Invoke-Tool 'wsl' @('--version'))
Add-Section 'Docker client' (Invoke-Tool 'docker' @('version', '--format', '{{.Client.Version}}'))
$dockerServer = Invoke-Tool 'docker' @('info', '--format', '{{.ServerVersion}}')
if ($dockerServer -match 'exit code|failed|not installed') { $dockerServer = "Docker engine: not running or not reachable`n$dockerServer" }
Add-Section 'Docker engine' $dockerServer
Add-Section 'Ollama' (Invoke-Tool 'ollama' @('--version'))

# --- Save
if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$file = Join-Path $OutputFolder ('{0}-{1}.txt' -f $FileNamePrefix, (Get-Date -Format $DateFormat))
$header = "Hardware report for $env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`n`r`n"
[IO.File]::WriteAllText($file, $header + $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

if ($ShowReport) { Write-Host ($header + $sb.ToString()) }
Write-Host "Report saved: $file" -ForegroundColor Green
