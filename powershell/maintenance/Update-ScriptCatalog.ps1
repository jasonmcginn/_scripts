<#
.SYNOPSIS
    Checks every script in the library against the house rules and rebuilds catalog.yaml.

.DESCRIPTION
    The script headers are the source of truth; catalog.yaml is generated from them,
    so the two can never drift. For each script it checks:
      - the header fields (Synopsis, Version, Status, Changes) are filled in
      - PowerShell scripts are named Verb-Noun with an approved verb
      - PowerShell scripts have a SETTINGS block at the top
      - nothing that looks like a secret is in the file (this repo is public)
      - no hard-coded absolute paths outside the header (use settings instead)
      - every deployed copy listed under Deployed exists and matches the library copy
      - each script has a man page (<script name>.md) next to it
    Prints a report and exits 1 if there are errors, so it can run before a commit.

.PARAMETER LibraryRoot
    The _scripts folder.

.PARAMETER CatalogPath
    Where catalog.yaml is written.

.PARAMETER NoWrite
    Check only; don't rewrite catalog.yaml.

.EXAMPLE
    .\Update-ScriptCatalog.ps1
    .\Update-ScriptCatalog.ps1 -NoWrite

.NOTES
    Version:     1.3.0
    Status:      draft
    Changes:     writes-files
    Requires:    Windows PowerShell 5.1 or PowerShell 7
    Author:      Jason R. McGinn
    Created:     2026-10-25
    Updated:     2026-10-25
    LastTested:  never
    Deployed:    none
#>
[CmdletBinding()]
param(
    # ================= SETTINGS: change these, or pass them on the command line =================
    [string]$LibraryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$CatalogPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'catalog.yaml'),
    [string[]]$Extensions = @('.ps1', '.psm1', '.py', '.sh'),
    [string[]]$SkipFolders = @('.git', '_templates', '_private'),
    [string[]]$SecretPatterns = @(
        '(?i)(password|passwd|pwd|secret|apikey|api_key|token)\s*[=:]\s*[''"][^''"\s$]{4,}',
        'sk-ant-[A-Za-z0-9_-]{10,}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        '(?i)AccountKey=[A-Za-z0-9+/=]{20,}',
        '(?i)[?&]sig=[A-Za-z0-9%]{10,}'
    ),
    [string[]]$ValidStatus = @('draft', 'tested', 'production', 'retired'),
    [string[]]$ValidChanges = @('reads-only', 'writes-files', 'changes-system'),
    [string]$DraftAllowedPattern = '^powershell[\\/]maintenance[\\/]',   # library tools may stay draft
    [int]$HeaderLines = 80,                                                # how far down headers are read
    [switch]$NoWrite
    # ============================================================================================
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$errors = New-Object System.Collections.Generic.List[string]
$warns  = New-Object System.Collections.Generic.List[string]
$fields = @('Version', 'Status', 'Changes', 'Requires', 'Author', 'Created', 'Updated', 'LastTested', 'Deployed')
$approvedVerbs = @(Get-Verb | ForEach-Object { $_.Verb })

function Get-HeaderField([string[]]$Lines, [string]$Name) {
    foreach ($l in $Lines) {
        if ($l -match "^\s*#?\s*$Name\s*:\s*(.+?)\s*(#.*)?$") { return $Matches[1].Trim() }
    }
    return ''
}

function Get-Synopsis([string[]]$Lines, [string]$Ext) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Ext -like '.ps*' -and $Lines[$i] -match '^\s*\.SYNOPSIS\s*$') {
            for ($k = $i + 1; $k -lt $Lines.Count; $k++) { if ($Lines[$k].Trim()) { return $Lines[$k].Trim() } }
        }
    }
    return (Get-HeaderField $Lines 'Synopsis')
}

function Get-VersionOf([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-HeaderField @(Get-Content -LiteralPath $Path -TotalCount $HeaderLines) 'Version')
}

if (-not (Test-Path -LiteralPath $LibraryRoot)) { throw "Library not found: $LibraryRoot" }
$root = (Resolve-Path -LiteralPath $LibraryRoot).Path.TrimEnd('\', '/')

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $parts = @($_.FullName.Substring($root.Length + 1) -split '[\\/]')
    $skipped = @($parts | Where-Object { $SkipFolders -contains $_ })
    ($Extensions -contains $_.Extension.ToLower()) -and ($skipped.Count -eq 0)
} | Sort-Object FullName)

$entries = @()
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $lines = @(Get-Content -LiteralPath $f.FullName)
    $text = $lines -join "`n"
    $headLines = @($lines | Select-Object -First $HeaderLines)
    $e = [ordered]@{ path = ($rel -replace '\\', '/'); name = $f.BaseName; language = $f.Extension.TrimStart('.') }
    $e['synopsis'] = Get-Synopsis $headLines $f.Extension
    foreach ($n in $fields) { $e[$n.ToLower()] = Get-HeaderField $headLines $n }

    foreach ($req in @('synopsis', 'version', 'status', 'changes')) {
        if (-not $e[$req]) { $errors.Add("${rel}: header is missing '$req'.") }
    }
    if ($e['status'] -and $ValidStatus -notcontains $e['status']) {
        $warns.Add("${rel}: status '$($e['status'])' is not one of: $($ValidStatus -join ', ').")
    }
    if ($e['status'] -eq 'draft' -and $rel -notmatch $DraftAllowedPattern) {
        $warns.Add("${rel}: status is draft. Drafts stay in their project until a working version is approved.")
    }
    if ($e['changes'] -and $ValidChanges -notcontains $e['changes']) {
        $warns.Add("${rel}: changes '$($e['changes'])' is not one of: $($ValidChanges -join ', ').")
    }

    if ($f.Extension -eq '.ps1') {
        if ($f.BaseName -notmatch '^([A-Z][a-z]+)-[A-Z][A-Za-z0-9]+$') {
            $errors.Add("${rel}: name is not Verb-Noun (for example Get-HardwareReport.ps1).")
        } elseif ($approvedVerbs -notcontains $Matches[1]) {
            $warns.Add("${rel}: '$($Matches[1])' is not an approved PowerShell verb (see Get-Verb).")
        }
        if ($text -notmatch 'SETTINGS') { $warns.Add("${rel}: no SETTINGS block at the top of the param section.") }
    }

    foreach ($p in $SecretPatterns) {
        if ($text -match $p) { $errors.Add("${rel}: possible secret matches pattern '$p'. This repo is public.") }
    }

    # Absolute paths outside the header (headers may describe paths; code should use settings)
    $bodyStart = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*#>\s*$') { $bodyStart = $i + 1; break } }
    for ($i = $bodyStart; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '[''"][A-Za-z]:\\' -or $lines[$i] -match '[''"]/(home|Users)/') {
            $warns.Add("${rel}: line $($i + 1) has a hard-coded absolute path; make it a setting.")
        }
    }

    # Man page next to the script
    $man = Join-Path $f.DirectoryName ($f.BaseName + '.md')
    if (Test-Path -LiteralPath $man) { $e['man'] = ($man.Substring($root.Length + 1) -replace '\\', '/') }
    else { $e['man'] = ''; $warns.Add("${rel}: no man page. Add $($f.BaseName).md next to it (template in _templates).") }

    # Deployed copies
    $deployState = @()
    $dep = $e['deployed']
    if ($dep -and $dep -ne 'none') {
        foreach ($d in ($dep -split ',')) {
            $d = $d.Trim(); if (-not $d) { continue }
            $target = Join-Path (Join-Path $root $d) $f.Name
            if (-not (Test-Path -LiteralPath $target)) {
                $warns.Add("${rel}: deployed copy missing at $target")
                $deployState += "${d}: missing"
            } elseif ((Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) {
                $deployState += "${d}: same"
            } else {
                $dv = Get-VersionOf $target
                $warns.Add("${rel}: deployed copy in $d differs (deployed version '$dv', library version '$($e['version'])').")
                $deployState += "${d}: differs (deployed $dv)"
            }
        }
    }
    $e['deployed_state'] = ($deployState -join '; ')
    $entries += $e
}

# ------------------------------------------------------------------
# Write the catalog (generated; never edit by hand)
# ------------------------------------------------------------------
function Format-YamlValue([string]$v) { return "'" + ($v -replace "'", "''") + "'" }

if (-not $NoWrite) {
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# GENERATED by powershell/maintenance/Update-ScriptCatalog.ps1. Do not edit by hand:')
    $out.Add('# change the script headers and run the tool again.')
    $out.Add("generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $out.Add("count: $($entries.Count)")
    $out.Add('scripts:')
    foreach ($e in $entries) {
        $first = $true
        foreach ($k in $e.Keys) {
            $prefix = '    '; if ($first) { $prefix = '  - '; $first = $false }
            $out.Add("$prefix${k}: $(Format-YamlValue ([string]$e[$k]))")
        }
    }
    [IO.File]::WriteAllLines($CatalogPath, $out, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
Write-Host ''
Write-Host ("Scripts found: {0}" -f $entries.Count) -ForegroundColor Cyan
foreach ($e in $entries) { Write-Host ("  {0,-50} {1,-8} {2,-11} {3}" -f $e['path'], $e['version'], $e['status'], $e['changes']) }
if ($warns.Count) { Write-Host ''; Write-Host "Warnings ($($warns.Count)):" -ForegroundColor Yellow; $warns | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow } }
if ($errors.Count) { Write-Host ''; Write-Host "Errors ($($errors.Count)):" -ForegroundColor Red; $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red } }
if (-not $NoWrite) { Write-Host ''; Write-Host "Catalog written: $CatalogPath" -ForegroundColor Green }
if ($errors.Count) { exit 1 }
exit 0
