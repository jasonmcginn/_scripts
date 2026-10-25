# Get-HardwareReport(1)

## NAME
**Get-HardwareReport** - write a plain-text report of this Windows machine's hardware and tooling.

## SYNOPSIS
```
Get-HardwareReport.ps1 [-OutputFolder <path>] [-FileNamePrefix <text>]
                       [-DateFormat <format>] [-LineWidth <n>] [-ShowReport]
```

## DESCRIPTION
Collects, in one UTF-8 text file:

- **Operating system:** edition, version, build, total RAM.
- **CPU:** name, cores, logical processors, clock speed.
- **GPU:** as Windows reports it, plus real VRAM from `nvidia-smi` when an NVIDIA card is present (Windows caps reported adapter memory at 4 GB).
- **Storage:** physical disks (type, size) and volumes (free and total space).
- **Tooling:** WSL, the Docker client, whether the Docker engine is running, and Ollama.

Tools that are missing or not running are reported as such; the script doesn't fail on them. It only reads system information and writes one report file.

## OPTIONS
All options are settings at the top of the script, with defaults, and can also be passed on the command line.

| Option | Default | Meaning |
|---|---|---|
| `-OutputFolder <path>` | your Documents folder | Where the report is saved; created if missing |
| `-FileNamePrefix <text>` | `hardware` | Start of the file name |
| `-DateFormat <format>` | `yyyy-MM-dd` | Date in the file name |
| `-LineWidth <n>` | 200 | Width used when formatting tables |
| `-ShowReport` | off | Also print the report to the console |

## FILES
`<OutputFolder>\<FileNamePrefix>-<date>.txt`: the report. A second run on the same day replaces that day's file.

## EXIT STATUS
0 on success. A non-zero code means a Windows query failed; the error is shown.

## EXAMPLES
```powershell
.\Get-HardwareReport.ps1
.\Get-HardwareReport.ps1 -ShowReport
.\Get-HardwareReport.ps1 -OutputFolder 'D:\Reports' -FileNamePrefix 'workstation'
```

## NOTES
- Needs Windows 10 or 11 with Windows PowerShell 5.1 or PowerShell 7. No administrator rights needed.
- The report names the computer; treat it as private before sharing.
- `Get-Help .\Get-HardwareReport.ps1 -Full` shows the built-in help.

## SEE ALSO
Update-ScriptCatalog(1)
