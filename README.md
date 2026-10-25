# _scripts
Scripts I've created to automate things, that I've chosen to share with the public.

Every script here is a **generic library copy**: settings sit at the top, so it runs anywhere once they're set. Configured copies run where they're needed and are tracked under `Deployed` in each script's header.

## Layout

```
_scripts/
├── catalog.yaml        generated index of every script (don't edit by hand)
├── powershell/
│   ├── system/         hardware, inventory, operating system
│   ├── backup/         backup and restore
│   ├── maintenance/    tools that look after this library
│   └── <category>/     network, security, azure ... created when the first script needs it
├── python/  bash/      same categories, created when needed
├── _templates/         starter file for each language, with the standard header
└── _archive/           retired scripts (status: retired), kept for reference
```

## Rules

1. **Names.** PowerShell: `Verb-Noun.ps1` with an approved verb (`Get-Verb`). Python and bash: `snake_case`.
2. **Header.** Every script starts with the standard header (copy from `_templates`): synopsis, version, status, what it changes, requirements, dates, last tested, where it's deployed.
3. **Settings at the top.** Folders and options are variables at the start of the script, with defaults, and can be overridden on the command line. No hard-coded paths in the body.
4. **No secrets, ever.** This repo is public. Keys and passwords come from a vault (KeePass) at run time.
5. **Outputs go elsewhere.** Reports, logs and data never land in this folder.
6. **Versions.** `MAJOR.MINOR.PATCH`. Bump the version and `Updated` with every change.
7. **Status:** `draft` (written) → `tested` (run and checked) → `production` (relied on) → `retired` (moved to `_archive`).
8. **Changes:** `reads-only`, `writes-files` or `changes-system`, so it's clear what a script can touch before running it.

## Keeping it organized

Run `powershell/maintenance/Update-ScriptCatalog.ps1` before each commit. It checks every script against the rules above, looks for anything that resembles a secret, compares deployed copies with the library copy, and rebuilds `catalog.yaml` from the headers.

## License

MIT. See `LICENSE`.
