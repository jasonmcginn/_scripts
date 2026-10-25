<#
.SYNOPSIS
    One line: what this script does.

.DESCRIPTION
    A few lines: what it does, what it reads, what it writes or changes.

.PARAMETER ExampleFolder
    What this setting controls.

.EXAMPLE
    .\Verb-Noun.ps1
    .\Verb-Noun.ps1 -ExampleFolder 'D:\somewhere'

.NOTES
    Version:     0.1.0
    Status:      draft            # draft | tested | production
    Changes:     reads-only       # reads-only | writes-files | changes-system
    Requires:    Windows PowerShell 5.1 or PowerShell 7
    Author:      Jason R. McGinn
    Created:     YYYY-MM-DD
    Updated:     YYYY-MM-DD
    LastTested:  never
    Deployed:    none             # folders where copies run, comma-separated, relative to _scripts (e.g. ..\Backups)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # ================= SETTINGS: change these, or pass them on the command line =================
    [string]$ExampleFolder = $PSScriptRoot
    # ============================================================================================
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Script body.
