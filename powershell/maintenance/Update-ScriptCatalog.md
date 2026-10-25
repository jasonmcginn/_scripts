# Update-ScriptCatalog(1)

## NAME
**Update-ScriptCatalog** - check every script in the library against the house rules and rebuild `catalog.yaml`.

## SYNOPSIS
```
Update-ScriptCatalog.ps1 [-LibraryRoot <path>] [-CatalogPath <path>] [-NoWrite]
                         [-Extensions <list>] [-SkipFolders <list>]
                         [-SecretPatterns <list>] [-ValidStatus <list>]
                         [-ValidChanges <list>] [-DraftAllowedPattern <regex>]
                         [-HeaderLines <n>]
```

## DESCRIPTION
The script headers are the source of truth; `catalog.yaml` is generated from them, so the two never drift. For each script it checks:

| Check | Level |
|---|---|
| Header has Synopsis, Version, Status and Changes | Error |
| PowerShell name is `Verb-Noun` | Error |
| The verb is an approved PowerShell verb (`Get-Verb`) | Warning |
| A `SETTINGS` block sits at the top of the parameters | Warning |
| Status and Changes use the allowed values | Warning |
| Drafts outside the library's own tools | Warning: drafts stay in their project until approved |
| A man page (`<script name>.md`) sits next to the script | Warning |
| Nothing resembles a secret (passwords, API keys, private keys, storage keys, signed URLs) | Error: the repo may be public |
| No hard-coded absolute paths outside the header | Warning: make them settings |
| Every deployed copy listed under `Deployed` exists and matches the library copy | Warning, with both versions |

Then it writes `catalog.yaml` (unless `-NoWrite`) and prints a report. Run it before every commit.

## OPTIONS
All options are settings at the top of the script, with defaults, and can also be passed on the command line.

| Option | Default | Meaning |
|---|---|---|
| `-LibraryRoot <path>` | two folders above the script | The library to check |
| `-CatalogPath <path>` | `catalog.yaml` in the library root | Where the catalog is written |
| `-NoWrite` | off | Check only; don't rewrite the catalog |
| `-Extensions <list>` | `.ps1 .psm1 .py .sh` | File types treated as scripts |
| `-SkipFolders <list>` | `.git _templates _private` | Folders never scanned |
| `-SecretPatterns <list>` | built-in list | Regular expressions that count as possible secrets |
| `-ValidStatus <list>` | `draft tested production retired` | Allowed `Status` values |
| `-ValidChanges <list>` | `reads-only writes-files changes-system` | Allowed `Changes` values |
| `-DraftAllowedPattern <regex>` | the maintenance folder | Paths whose scripts may stay `draft` |
| `-HeaderLines <n>` | 80 | How far down each file the header is read |

## THE HEADER
Fields the tool reads, from the `.NOTES` block of a PowerShell script or a `# Key: value` comment block in other languages:

`Version`, `Status`, `Changes`, `Requires`, `Author`, `Created`, `Updated`, `LastTested`, `Deployed`. PowerShell's synopsis comes from `.SYNOPSIS`; other languages use a `Synopsis:` line.

`Deployed` lists folders, relative to the library root and comma-separated, where configured copies of the script run, for example `..\Backups`. Use `none` if there are none.

## FILES
`catalog.yaml` in the library root: generated, never edited by hand.

## EXIT STATUS
| Code | Meaning |
|---|---|
| 0 | No errors (warnings may still be shown) |
| 1 | At least one error; fix before committing |

## EXAMPLES
```powershell
.\powershell\maintenance\Update-ScriptCatalog.ps1
.\powershell\maintenance\Update-ScriptCatalog.ps1 -NoWrite
.\powershell\maintenance\Update-ScriptCatalog.ps1 -ValidStatus draft,tested,production,retired,deprecated
```

## SEE ALSO
`README.md` (house rules), `_templates\`
