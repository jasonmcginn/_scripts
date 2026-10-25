# Invoke-Backup(1)

## NAME
**Invoke-Backup** - run the backup jobs defined in a manifest, verify every file, and report backup health.

## SYNOPSIS
```
Invoke-Backup.ps1 [-ManifestPath <path>] [-Job <id>[,<id>...]] [-WhatIf]
                  [-InstallMissing] [-HistoryCount <n>] [-RobocopyRetries <n>]
                  [-RobocopyWaitSeconds <n>] [-HashFileName <name>]
                  [-MaxMismatchesShown <n>] [-DefaultStaleDays <n>]
Invoke-Backup.ps1 -ShowHistory [-HistoryCount <n>] [-ManifestPath <path>]
```

## DESCRIPTION
Reads a YAML manifest that describes what to back up, where to, and how. For each enabled job it:

1. holds running containers still, if the job asks for it (see **CONSISTENCY**),
2. copies the source into a new dated folder with robocopy (never overwriting an earlier backup),
3. verifies every copied file against its source by hash,
4. writes the list of hashes into the backup folder,
5. releases any held containers, even if the copy failed,
6. appends one line per job to the history file.

A health check runs before and after the jobs and warns loudly about anything that leaves backups unprotected: jobs never run or not configured, stale or failed backups, missing copies in the 3-2-1 plan, and restore tests never done or overdue.

**The script never deletes anything.** Backups that fall outside the retention policy are listed for you to remove by hand.

## OPTIONS
All options are settings at the top of the script, with defaults, and can also be passed on the command line.

| Option | Default | Meaning |
|---|---|---|
| `-ManifestPath <path>` | `backup-manifest.yaml` next to the script | The manifest to read |
| `-Job <id>[,<id>]` | every enabled job | Run only these jobs |
| `-WhatIf` | off | Dry run: show what each job would do; copy nothing, write no history |
| `-ShowHistory` | off | Show recent runs as a table, then stop. Copies nothing |
| `-HistoryCount <n>` | 20 | Runs shown by `-ShowHistory` |
| `-InstallMissing` | off | Install missing dependencies without asking (unattended runs) |
| `-RobocopyRetries <n>` | 1 | robocopy `/R`: retries per file |
| `-RobocopyWaitSeconds <n>` | 1 | robocopy `/W`: seconds between retries |
| `-HashFileName <name>` | `hashes.sha256` | Name of the hash list in each backup folder |
| `-MaxMismatchesShown <n>` | 10 | Mismatches listed one by one before they're only counted |
| `-DefaultStaleDays <n>` | 7 | Warn when a job's last success is older than this, if the manifest sets no limit |

## THE MANIFEST
Backup **policy** lives in the manifest; the script's own **behaviour** lives in its settings. A starting manifest with every option commented is in `backup-manifest.example.yaml` next to this page. Copy it beside the script as `backup-manifest.yaml` and edit it.

| Section | Holds |
|---|---|
| `defaults` | Settings every job inherits: backup root, history file, logs folder, folder name format, verify options, retention, excludes, consistency |
| `jobs` | One entry per thing backed up: `id`, `name`, `enabled`, `source`, `destination_subfolder`, plus any default it overrides. `exclude_add` adds to the default excludes; `exclude` replaces them |
| `copies` | The 3-2-1 plan: each copy with its media and `status` (`configured` or `missing`) |
| `restore_test` | `interval_days` and `last_tested` (set by hand after a test restore) |
| `alerts` | `warn_when` conditions, including `last_success_older_than_days` |

**Exclude patterns:** a trailing `\` means a folder; a pattern containing `\` is a path under the source; anything else is a file name or wildcard.

## CONSISTENCY
Each job's `consistency` setting decides how files are held still while they're copied and verified. `containers` lists the name prefixes to hold, for example `['core-', 'agt-']`.

| Mode | Interruption | What happens |
|---|---|---|
| `live` | None | Copy while running. Files that change mid-copy fail the hash check; run again |
| `pause` | Seconds | Freeze matching running containers, copy, unfreeze. No restart |
| `stop` | A full restart | Stop matching containers, copy, start them again |
| `snapshot` | None | Copy from a Windows shadow copy. **Not built yet:** uses `pause` and warns |

Only running containers are held; if none match, nothing is changing the files and the copy goes ahead. If Docker can't release a container, the script says so in capitals and names it.

## DEPENDENCIES
Checked at the start of every run:

| Dependency | Needed for | If missing |
|---|---|---|
| robocopy | Copying (built into Windows) | Stops |
| powershell-yaml module | Reading the manifest | Asks to install it for the current user (no administrator rights needed). Stops if declined or nobody can answer, unless `-InstallMissing` |
| Docker | Holding containers (`pause`, `stop`, `snapshot`) | Reported; jobs copy without holding, since nothing can be running |
| Administrator rights | `snapshot`, once built | Warns for snapshot jobs; not needed for anything else |

## FILES
| Path | Purpose |
|---|---|
| `backup-manifest.yaml` | Configuration, edited by you. The script never changes it |
| `<backup_root>\<history_file>` | History: one JSON line per job run, appended by the script |
| `<backup_root>\<logs_folder>\` | One robocopy log per job run |
| `<backup_root>\<destination_subfolder>\<date>\` | Each backup, mirroring its source |
| `...\<date>\<HashFileName>` | Hash of every file in that backup |

## EXIT STATUS
| Code | Meaning |
|---|---|
| 0 | Every job that ran succeeded (warnings may still be shown) |
| 1 | At least one job failed |
| 2 | Could not start: missing dependency or manifest |

## EXAMPLES
```powershell
.\Invoke-Backup.ps1 -WhatIf                     # dry run of every enabled job
.\Invoke-Backup.ps1                             # back up every enabled job
.\Invoke-Backup.ps1 -Job documents,projects     # only these jobs
.\Invoke-Backup.ps1 -ShowHistory -HistoryCount 5
.\Invoke-Backup.ps1 -InstallMissing             # unattended, e.g. from Task Scheduler
.\Invoke-Backup.ps1 -ManifestPath 'D:\Backups\backup-manifest.yaml'
```

## NOTES
- Close apps that write to a source, or use a consistency mode, before backing it up.
- Same-day runs never overwrite: a second run adds the time to the folder name.
- A backup that has never been restored is unproven. Test a restore, then set `restore_test.last_tested`.
- `Get-Help .\Invoke-Backup.ps1 -Full` shows the built-in help.

## SEE ALSO
`backup-manifest.example.yaml`, Update-ScriptCatalog(1)
