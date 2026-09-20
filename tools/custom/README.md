# Custom build tools (personal)

Scripts for building and installing this fork plus a set of community plugins after an EverQuest patch.
The plugin sources themselves are **not** stored here (they belong to their authors and `plugins\` is
git-ignored); `plugin-commits.txt` records where each came from and which commit was built.

| File | Purpose |
|---|---|
| `Rebuild-Plugins.ps1` | Builds core + every plugin under `plugins\`, checks each DLL is stamped for the installed client, and installs into a test folder with a backup. |
| `Restore-Plugins.ps1` | Re-creates `plugins\` from `plugin-commits.txt` (clone each repo and check out the recorded commit). |
| `plugin-commits.txt` | `folder \| commit \| remote` for each plugin repo. Updated automatically by `Rebuild-Plugins.ps1`. |

`plugins\Rebuild-Plugins.ps1` is a one-line forwarder to the script here, so older commands still work.

## After an EQ patch (close EverQuest and the MacroQuest launcher first)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Rebuild-Plugins.ps1 -Sync -ApplyOfficial -Update
```

* `-Sync` fetches RedGuides' official eqlib (`redguides/eqlib`, branch `live`) and checks it matches the installed `eqgame.exe`.
  If RedGuides has not published the patch yet, the script says so and stops.
* `-ApplyOfficial` switches `src\eqlib` to a local branch `official-live` at that commit. Commit the submodule pointer afterwards,
  and push the eqlib branch to your fork **before** pushing the main repo.
* `-Update` runs `git pull --ff-only` in each plugin repo first (leave it off to stay pinned to `plugin-commits.txt`).
* Other switches: `-DryRun`, `-CoreOnly` (address-only fixes), `-SkipCore`, `-Only MQ2Nav`, `-InstallDir`, `-EQDir`, `-SkipVerify`.

## On a new machine

1. Clone the fork with submodules; install Visual Studio 2022 Build Tools (C++ workload) and Git.
2. `tools\custom\Restore-Plugins.ps1` to bring back the plugin sources at the recorded commits.
3. `tools\custom\Rebuild-Plugins.ps1` to build and install.

## Notes

* The CWTN class plugins are intentionally not built (no public source).
* Rollback tag for the last hand-maintained state: `known-good-2026-09-20` (main repo and eqlib).
