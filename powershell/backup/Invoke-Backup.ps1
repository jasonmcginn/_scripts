<#
.SYNOPSIS
    Runs the backups defined in backup-manifest.yaml.

.DESCRIPTION
    Reads the manifest, then for each enabled job:
      1. copies the source to a new dated folder with robocopy (never overwrites),
      2. verifies every copied file against its source by SHA256,
      3. writes hashes.sha256 into the backup folder,
    Jobs can hold running containers still while they copy (consistency: live,
    pause, stop, snapshot; see the manifest), and always release them afterwards.
      4. appends one line to the history file (backup-history.jsonl).
    Health warnings (3-2-1 gaps, untested restores, stale or failed backups,
    unconfigured jobs) are printed loudly at the start and the end of every run.

    This script never deletes anything. Retention is reported only: backups
    that fall outside the retention policy are listed as candidates for you
    to remove by hand.

.PARAMETER ManifestPath
    Path to the manifest. Defaults to backup-manifest.yaml next to this script.

.PARAMETER Job
    One or more job ids to run. Defaults to every enabled job.

.EXAMPLE
    .\Invoke-Backup.ps1
    .\Invoke-Backup.ps1 -Job professional-profile
    .\Invoke-Backup.ps1 -WhatIf

.NOTES
    Version:     1.1.0
    Status:      draft
    Changes:     writes-files
    Requires:    Windows PowerShell 5.1 or PowerShell 7; robocopy (built in);
                 powershell-yaml module (Install-Module powershell-yaml -Scope CurrentUser)
    Author:      Jason R. McGinn
    Created:     2026-10-25
    Updated:     2026-10-25
    LastTested:  never
    Deployed:    ..\Backups        # relative to the _scripts folder
    Manifest:    version 1 (backup-manifest.yaml sits next to the deployed copy)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # ================= SETTINGS: change these, or pass them on the command line =================
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'backup-manifest.yaml'),   # all folders and options live in the manifest
    [string[]]$Job                                                               # empty = every enabled job
    # ============================================================================================
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Add-Warning([string]$Message) {
    $script:Warnings.Add($Message)
    Write-Host "  WARNING: $Message" -ForegroundColor Yellow
}

function Get-Setting($JobDef, $Defaults, [string]$Name) {
    if ($JobDef.ContainsKey($Name) -and $null -ne $JobDef[$Name]) { return $JobDef[$Name] }
    return $Defaults[$Name]
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Get-HoldTargets([string[]]$Prefixes) {
    # Running containers whose names start with any of the prefixes. Empty if Docker isn't available.
    if (-not $Prefixes -or $Prefixes.Count -eq 0) { return @() }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return @() }
    $ErrorActionPreference = 'Continue'
    $names = @(& docker ps --format '{{.Names}}' 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($names | Where-Object { $n = $_; @($Prefixes | Where-Object { $n.StartsWith($_) }).Count -gt 0 })
}

function Invoke-Hold([string]$Mode, [string[]]$Names, [switch]$Release) {
    # pause/unpause or stop/start the named containers. Throws if Docker refuses.
    $verb = switch ($Mode) {
        'pause' { if ($Release) { 'unpause' } else { 'pause' } }
        'stop'  { if ($Release) { 'start' }   else { 'stop' } }
    }
    $ErrorActionPreference = 'Continue'
    $out = & docker $verb @Names 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $verb failed: $($out -join ' ')" }
}

function Get-RetentionCandidates([string]$Parent, $Retention) {
    # Grandfather-father-son: keep the newest backup of each of the last N days,
    # N weeks and N months. Everything else is a candidate. Report only.
    if (-not (Test-Path -LiteralPath $Parent)) { return @() }
    $items = @(Get-ChildItem -LiteralPath $Parent -Directory | ForEach-Object {
        $dt = [datetime]::MinValue
        if ($_.Name.Length -ge 10 -and
            [datetime]::TryParseExact($_.Name.Substring(0, 10), 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$dt)) {
            [pscustomobject]@{ Name = $_.Name; Date = $dt }
        }
    } | Sort-Object -Property @{Expression = 'Date'; Descending = $true}, @{Expression = 'Name'; Descending = $true})

    $cal = [Globalization.CultureInfo]::InvariantCulture.Calendar
    $rules = @(
        @{ Count = [int]$Retention.keep_daily;   Key = { param($d) $d.ToString('yyyy-MM-dd') } },
        @{ Count = [int]$Retention.keep_weekly;  Key = { param($d) '{0}-W{1}' -f $d.Year, $cal.GetWeekOfYear($d, 'FirstFourDayWeek', 'Monday') } },
        @{ Count = [int]$Retention.keep_monthly; Key = { param($d) $d.ToString('yyyy-MM') } }
    )
    $keep = @{}
    foreach ($rule in $rules) {
        $seen = @{}
        foreach ($it in $items) {
            $k = & $rule.Key $it.Date
            if (-not $seen.ContainsKey($k) -and $seen.Count -lt $rule.Count) {
                $seen[$k] = $true
                $keep[$it.Name] = $true
            }
        }
    }
    return @($items | Where-Object { -not $keep.ContainsKey($_.Name) })
}

# ------------------------------------------------------------------
# Load the manifest
# ------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'The powershell-yaml module is needed to read the manifest. Install it once with:' -ForegroundColor Red
    Write-Host '    Install-Module powershell-yaml -Scope CurrentUser' -ForegroundColor Red
    exit 2
}
Import-Module powershell-yaml

if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$m = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Yaml
$d = $m['defaults']
$root = $d['backup_root']
$historyPath = Join-Path $root $d['history_file']
$logDir = Join-Path $root $d['logs_folder']
if (-not (Test-Path -LiteralPath $root)) { throw "Backup root not found: $root" }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

function Get-History {
    if (-not (Test-Path -LiteralPath $historyPath)) { return @() }
    return @(Get-Content -LiteralPath $historyPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

# Thresholds from the alerts section
$staleDays = 7
foreach ($w in @($m['alerts']['warn_when'])) {
    if ($w -is [System.Collections.IDictionary] -and $w.Contains('last_success_older_than_days')) {
        $staleDays = [int]$w['last_success_older_than_days']
    }
}

# ------------------------------------------------------------------
# Health check (runs every time, loud on purpose)
# ------------------------------------------------------------------
function Invoke-HealthCheck {
    $history = Get-History
    foreach ($j in @($m['jobs'])) {
        $src = [string]$j['source']
        if ($j['enabled'] -ne $true -or $src -like '*TBD*') {
            Add-Warning "Job '$($j['id'])' ($($j['name'])) is disabled or not configured."
            continue
        }
        $runs = @($history | Where-Object { $_.job -eq $j['id'] })
        $ok = @($runs | Where-Object { $_.status -eq 'success' })
        if ($ok.Count -eq 0) {
            Add-Warning "Job '$($j['id'])' has never completed a successful backup."
        } else {
            $last = [datetime]($ok[-1].time)
            $age = ((Get-Date) - $last).Days
            if ($age -gt $staleDays) { Add-Warning "Job '$($j['id'])' last succeeded $age days ago (limit $staleDays)." }
        }
        if ($runs.Count -gt 0 -and $runs[-1].status -ne 'success') {
            Add-Warning "Job '$($j['id'])' failed on its last run ($($runs[-1].time)): $($runs[-1].message)"
        }
    }
    foreach ($c in @($m['copies'])) {
        if ($c['status'] -ne 'configured') {
            Add-Warning "3-2-1 not met: copy '$($c['id'])' ($($c['description'])) is $($c['status'])."
        }
    }
    $rt = $m['restore_test']
    if ($null -eq $rt['last_tested'] -or "$($rt['last_tested'])" -eq '') {
        Add-Warning 'Restore has never been tested. A backup that has never been restored is unproven.'
    } else {
        $age = ((Get-Date) - [datetime]"$($rt['last_tested'])").Days
        if ($age -gt [int]$rt['interval_days']) { Add-Warning "Restore test is overdue: last tested $age days ago (every $($rt['interval_days']) days)." }
    }
}

Write-Section 'Backup health (before this run)'
Invoke-HealthCheck
if ($script:Warnings.Count -eq 0) { Write-Host '  All checks passed.' -ForegroundColor Green }
$script:Warnings.Clear()   # from here on, collect only this run's problems

# ------------------------------------------------------------------
# Choose jobs
# ------------------------------------------------------------------
$jobs = @(@($m['jobs']) | Where-Object { $_['enabled'] -eq $true -and ([string]$_['source']) -notlike '*TBD*' })
if ($Job) {
    $ids = @($jobs | ForEach-Object { $_['id'] })
    foreach ($want in $Job) { if ($ids -notcontains $want) { Add-Warning "Job '$want' was requested but is not found or not enabled." } }
    $jobs = @($jobs | Where-Object { $Job -contains $_['id'] })
}

# ------------------------------------------------------------------
# Run jobs
# ------------------------------------------------------------------
$results = @()
foreach ($j in $jobs) {
    $id = $j['id']
    Write-Section "Job: $id ($($j['name']))"
    $started = Get-Date
    $status = 'failed'; $message = ''; $rc = $null; $count = 0; $bytes = 0; $mismatch = 0
    $dest = $null; $log = $null; $mode = $null; $held = @(); $holdStart = $null; $holdSeconds = 0

    try {
        $src = [string]$j['source']
        if (-not (Test-Path -LiteralPath $src)) { throw "Source not found: $src" }

        $method = Get-Setting $j $d 'method'
        if ($method -eq 'compress') { Add-Warning "Job '$id': compress is not built yet. Copying instead." }

        $stamp = Get-Date -Format (Get-Setting $j $d 'folder_name_format')
        $destParent = Join-Path $root $j['destination_subfolder']
        $dest = Join-Path $destParent $stamp
        if (Test-Path -LiteralPath $dest) { $dest = '{0}_{1}' -f $dest, (Get-Date -Format 'HHmmss') }   # never overwrite
        if ($dest.StartsWith($src.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Destination is inside the source: $dest" }

        # Exclusions: trailing \ = folder; containing \ = path under the source; otherwise a name or wildcard
        $excludes = @()
        if ($j.ContainsKey('exclude') -and $null -ne $j['exclude']) { $excludes = @($j['exclude']) } else { $excludes = @($d['exclude']) }
        if ($j.ContainsKey('exclude_add') -and $null -ne $j['exclude_add']) { $excludes += @($j['exclude_add']) }
        $xf = @(); $xd = @()
        foreach ($p in $excludes) {
            if ($p.EndsWith('\')) {
                $name = $p.TrimEnd('\')
                if ($name.Contains('\')) { $xd += (Join-Path $src $name) } else { $xd += $name }
            } else {
                if ($p.Contains('\')) { $xf += (Join-Path $src $p) } else { $xf += $p }
            }
        }

        # Consistency: how files are held still while they're copied (see the manifest)
        $mode = [string](Get-Setting $j $d 'consistency')
        if (-not $mode) { $mode = 'live' }
        if (@('live', 'pause', 'stop', 'snapshot') -notcontains $mode) { throw "Unknown consistency '$mode' (use live, pause, stop or snapshot)." }
        $holdMode = $mode
        if ($mode -eq 'snapshot') {
            Add-Warning "Job '$id': snapshot is not built yet. Using pause instead."
            $holdMode = 'pause'
        }
        $targets = @()
        if ($holdMode -ne 'live') { $targets = @(Get-HoldTargets @(Get-Setting $j $d 'containers')) }

        Write-Host "  Source:      $src"
        Write-Host "  Destination: $dest"
        Write-Host "  Consistency: $mode$(if ($targets.Count) { " ($($targets.Count) container(s): $($targets -join ', '))" } elseif ($holdMode -ne 'live') { ' (no matching containers running, so nothing is changing the files)' })"
        if (-not $PSCmdlet.ShouldProcess($dest, "Copy $src")) {
            $status = 'whatif'; $message = 'Dry run, nothing copied.'
        } else {
          if ($targets.Count -gt 0) {
              Write-Host "  Holding containers ($holdMode)..."
              Invoke-Hold $holdMode $targets
              $held = $targets; $holdStart = Get-Date
          }
          try {
            $log = Join-Path $logDir ('{0}_{1}.log' -f $id, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
            $rcArgs = @($src, $dest, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NP', "/UNILOG:$log")
            if ($xf.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $xf }
            if ($xd.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $xd }

            Write-Host '  Copying with robocopy...'
            & robocopy @rcArgs | Out-Null
            $rc = $LASTEXITCODE
            if ($rc -ge 8) { throw "robocopy failed with exit code $rc. See $log" }
            if (-not (Test-Path -LiteralPath $dest)) { throw "Nothing was copied (robocopy exit $rc). See $log" }

            # Verify: every copied file must match its source
            Write-Host '  Verifying SHA256 hashes...'
            $lines = New-Object System.Collections.Generic.List[string]
            $files = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force)
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($dest.Length).TrimStart('\')
                $srcFile = Join-Path $src $rel
                try {
                    $hd = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                    $hs = (Get-FileHash -LiteralPath $srcFile -Algorithm SHA256).Hash
                } catch { $hd = 'ERROR'; $hs = $null }
                if ($hd -ne $hs) {
                    $mismatch++
                    if ($mismatch -le 10) { Add-Warning "Hash mismatch or unreadable: $rel" }
                }
                $lines.Add("$hd  $rel")
                $count++; $bytes += $f.Length
            }
            if ($mismatch -gt 10) { Add-Warning "...and $($mismatch - 10) more mismatches." }
            [IO.File]::WriteAllLines((Join-Path $dest 'hashes.sha256'), $lines)

            if ($mismatch -gt 0) {
                $message = "$mismatch file(s) did not match their source. A file may have changed during the backup; close open apps and run again."
                $status = 'failed'
            } else {
                $status = 'success'
                $message = "robocopy exit $rc"
            }
          } finally {
            # Always release held containers, even if the copy failed
            if ($held.Count -gt 0) {
                try {
                    Invoke-Hold $holdMode $held -Release
                    $holdSeconds = [math]::Round(((Get-Date) - $holdStart).TotalSeconds, 1)
                    Write-Host "  Released $($held.Count) container(s) after $holdSeconds s."
                } catch {
                    Add-Warning "COULD NOT RELEASE CONTAINERS ($holdMode): $($held -join ', '). Release them by hand. $($_.Exception.Message)"
                }
            }
          }

            # Retention: report only
            $cands = @(Get-RetentionCandidates $destParent (Get-Setting $j $d 'retention'))
            if ($cands.Count -gt 0) {
                Write-Host "  Outside retention (NOT deleted; remove by hand if you agree):" -ForegroundColor Yellow
                $cands | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
            }
        }
    } catch {
        $status = 'failed'
        $message = $_.Exception.Message
        Write-Host "  FAILED: $message" -ForegroundColor Red
    }

    $duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    if ($status -ne 'whatif') {
        $rec = [ordered]@{
            time            = (Get-Date).ToString('o')
            job             = $id
            status          = $status
            source          = [string]$j['source']
            destination     = $dest
            files           = $count
            bytes           = $bytes
            hash_mismatches = $mismatch
            robocopy_exit   = $rc
            consistency     = $mode
            held_containers = $held.Count
            hold_s          = $holdSeconds
            duration_s      = $duration
            log             = $log
            message         = $message
        }
        [IO.File]::AppendAllText($historyPath, (ConvertTo-Json $rec -Compress) + [Environment]::NewLine)
    }

    $color = 'Green'; if ($status -eq 'failed') { $color = 'Red' } elseif ($status -eq 'whatif') { $color = 'Gray' }
    Write-Host ("  Result: {0}  ({1} files, {2:N1} MB, {3}s)" -f $status.ToUpper(), $count, ($bytes / 1MB), $duration) -ForegroundColor $color
    $results += [pscustomobject]@{ Job = $id; Status = $status; Files = $count; MB = [math]::Round($bytes / 1MB, 1); Seconds = $duration }
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Section 'Summary'
if ($results.Count -gt 0) { Write-Host ($results | Format-Table -AutoSize | Out-String).TrimEnd() } else { Write-Host '  No jobs ran.' }

if ($script:Warnings.Count -gt 0) {
    Write-Host ("  {0} problem(s) during this run (listed above)." -f $script:Warnings.Count) -ForegroundColor Yellow
}

Write-Section 'Backup health (after this run)'
$script:Warnings.Clear()
Invoke-HealthCheck
if ($script:Warnings.Count -eq 0) {
    Write-Host '  All checks passed.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host ("  {0} WARNING(S): backups are not fully protected until these are fixed." -f $script:Warnings.Count) -ForegroundColor Yellow
}

if (@($results | Where-Object { $_.Status -eq 'failed' }).Count -gt 0) { exit 1 }
exit 0
