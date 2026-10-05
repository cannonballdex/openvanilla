<#
.SYNOPSIS
    One command for "EverQuest just patched, get MacroQuest working again".

.DESCRIPTION
    Default run (everything up to, and including, a ready-to-test install):
      1. Checks nothing in <InstallDir> is in use (EQ running from another install is fine)
         and shows the client build dates.
      2. Checks src\eqlib has no uncommitted changes.
      3. Asks RedGuides' official eqlib whether it matches the client you have installed.
         If they have not published it yet, it STOPS here and tells you to try later.
         Then lists any MacroQuest core fixes RedGuides has that your branch lacks (read-only).
      4. Runs Rebuild-Plugins.ps1 -Sync -ApplyOfficial -Update (build everything, verify version
         stamps, install with a backup).
      5. Optionally launches MacroQuest (-Launch) so you can test.

    After you have tested in game, run it again with -Publish to save the result to GitHub
    (eqlib branch first, then the main repo). Nothing personal is added; only the eqlib
    pointer and tools\custom\plugin-commits.txt.

.PARAMETER Launch    Start MacroQuest when the install succeeds.
.PARAMETER Publish   Do NOT build. Commit + push the result of a successful update (run after testing).
.PARAMETER DryRun    Do steps 1-3 only (read-only). Builds and changes nothing.
.PARAMETER InstallDir  Default C:\MQNext-LiveTest
.PARAMETER EQDirs      EverQuest folders to show build dates for. Default C:\EverQuest, C:\EverQuest2

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Update-AfterPatch.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Update-AfterPatch.ps1 -Launch
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Update-AfterPatch.ps1 -Publish
#>
[CmdletBinding()]
param(
    [switch]$Launch,
    [switch]$Publish,
    [switch]$DryRun,
    [string]$InstallDir = 'C:\MQNext-LiveTest',
    [string[]]$EQDirs   = @('C:\EverQuest', 'C:\EverQuest2')
)

$ErrorActionPreference = 'Stop'

# repo root = walk up from this script until src\MacroQuest.sln
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path (Join-Path $repo 'src\MacroQuest.sln'))) { $repo = Split-Path -Parent $repo }
if (-not $repo) { throw "Could not find the openvanilla repo above $PSScriptRoot." }
$eqlib   = Join-Path $repo 'src\eqlib'
$rebuild = Join-Path $PSScriptRoot 'Rebuild-Plugins.ps1'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Stop-Here([string]$m) { Say ''; Say $m 'Yellow'; exit 1 }
function Invoke-G([string]$dir, [string[]]$a) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & git -C $dir @a 2>&1 | ForEach-Object { "$_" }; $ok = ($LASTEXITCODE -eq 0) } finally { $ErrorActionPreference = $prev }
    return @{ Ok = $ok; Out = ($o -join "`n").Trim() }
}
function Run-Rebuild([string[]]$a) {
    $script:rbOut = @()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rebuild @a 2>&1 | ForEach-Object { Write-Host $_; $script:rbOut += "$_" }
    return $LASTEXITCODE
}

# Core fixes (MacroQuest itself, not offsets) that RedGuides has and this branch does not.
# Read-only: lists them so they can be cherry-picked by hand before building.
function Show-MissingCoreFixes {
    Say ''; Say 'Checking for RedGuides core fixes missing from your branch ...' 'Cyan'
    $sources = @(
        @{ Name = 'macroquest/macroquest master'; Url = 'https://github.com/macroquest/macroquest.git'; Ref = 'refs/remotes/check/macroquest' },
        @{ Name = 'RedGuides/openvanilla master'; Url = 'https://github.com/RedGuides/openvanilla.git'; Ref = 'refs/remotes/check/openvanilla' }
    )
    $any = $false
    foreach ($s in $sources) {
        $f = Invoke-G $repo @('fetch', '--quiet', $s.Url, "+master:$($s.Ref)")
        if (-not $f.Ok) { Say "  could not fetch $($s.Name), skipped." 'DarkYellow'; continue }
        # commits not already in HEAD (cherry-picks count as present); eqlib pointer moves are handled by -ApplyOfficial
        $log = (Invoke-G $repo @('log', '--cherry-pick', '--right-only', '--no-merges', '--format=    %h %cs %s',
            "HEAD...$($s.Ref)", '--', '.', ':!src/eqlib')).Out
        if ($log) { $any = $true; Say "  $($s.Name):" 'Yellow'; Say $log 'Yellow' }
    }
    if ($any) {
        Say '  These are NOT applied automatically. To take one:  git -C "<repo>" cherry-pick -x <hash>  then run the update.' 'Yellow'
    } else {
        Say '  none: your branch has every RedGuides core fix.' 'Green'
    }
}

Say "=== After-patch update  $(Get-Date) ===" 'Cyan'

# ------------------------------------------------------------------ -Publish
if ($Publish) {
    Say 'Publishing to GitHub (nothing is built).' 'Cyan'
    $br  = (Invoke-G $eqlib @('branch', '--show-current')).Out
    $mbr = (Invoke-G $repo  @('branch', '--show-current')).Out
    if (-not $br)  { Stop-Here 'src\eqlib is not on a branch (detached). Run the update first (without -Publish).' }
    Say "  eqlib branch : $br"; Say "  main branch  : $mbr"

    if ((Invoke-G $eqlib @('status', '--porcelain')).Out) { Stop-Here 'src\eqlib has uncommitted changes; will not publish.' }

    # 1) eqlib branch FIRST, so the main repo's submodule pointer resolves on your fork
    Say 'Pushing eqlib branch to your fork ...' 'Cyan'
    $p1 = Invoke-G $eqlib @('push', 'origin', $br)
    Say ("  " + ($p1.Out -split "`n" | Select-Object -Last 2 | Out-String).Trim())
    if (-not $p1.Ok) { Stop-Here "eqlib push failed. Nothing else was pushed." }

    # 2) main repo: only the eqlib pointer + the plugin record
    $h = Get-Content (Join-Path $eqlib 'include\eqlib\offsets\eqgame.h') -Raw
    $v = if ($h -match '__ExpectedVersionDate\s+"([^"]+)"[\s\S]*?__ExpectedVersionTime\s+"([^"]+)"') { "$($Matches[1]) $($Matches[2])" } else { 'new patch' }
    $null = Invoke-G $repo @('add', 'src/eqlib', 'tools/custom/plugin-commits.txt')
    if ((Invoke-G $repo @('diff', '--cached', '--name-only')).Out) {
        $c = Invoke-G $repo @('commit', '-m', "live: update to official eqlib for client $v")
        if (-not $c.Ok) { Stop-Here "Commit failed: $($c.Out)" }
        Say "  committed: $((Invoke-G $repo @('log','-1','--format=%h %s')).Out)"
    } else { Say '  nothing new to commit in the main repo.' }
    Say 'Pushing main repo ...' 'Cyan'
    $p2 = Invoke-G $repo @('push', 'origin', $mbr)
    Say ("  " + ($p2.Out -split "`n" | Select-Object -Last 2 | Out-String).Trim())
    if (-not $p2.Ok) { Stop-Here 'Main repo push failed.' }
    Say ''; Say 'Published. Both repos are on GitHub.' 'Green'
    exit 0
}

# ------------------------------------------- 1. install folder not in use?
# EverQuest running with MacroQuest from another install (e.g. C:\MQNext) locks nothing here.
$locked = @()
if (Test-Path $InstallDir) {
    $binFiles = @(Get-ChildItem $InstallDir, (Join-Path $InstallDir 'plugins') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.dll', '.exe' })
    foreach ($f in $binFiles) {
        try { $s = [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'None'); $s.Close() }
        catch { $locked += $f.Name }
    }
}
if ($locked.Count -and -not $DryRun) { Stop-Here ("Close the EverQuest / MacroQuest that is running from $InstallDir first, then run this again. In use: " + (($locked | Select-Object -First 5) -join ', ')) }
Say "$InstallDir : not in use." 'Green'

Say 'Client builds on disk:'
foreach ($d in $EQDirs) {
    $e = Join-Path $d 'eqgame.exe'
    if (Test-Path $e) { Say ("  {0,-16} {1:yyyy-MM-dd HH:mm}" -f $d, (Get-Item $e).LastWriteTime) } else { Say ("  {0,-16} (no eqgame.exe)" -f $d) 'DarkYellow' }
}

# ---------------------------------------------------- 2. eqlib must be clean
$dirty = (Invoke-G $eqlib @('status', '--porcelain')).Out
if ($dirty) { Stop-Here "src\eqlib has uncommitted changes, so switching it could lose them:`n$dirty`nCommit or stash them first." }
Say 'src\eqlib: clean.' 'Green'

# --------------------------------------- 3. has RedGuides published this patch?
Say ''; Say 'Asking RedGuides whether their official offsets match your installed client ...' 'Cyan'
$rc = Run-Rebuild @('-DryRun', '-Sync')
$text = $script:rbOut -join "`n"
if ($rc -ne 0) { Stop-Here 'The check itself failed (see above). Nothing was changed.' }
if ($text -match 'NOT for your installed client yet') {
    Stop-Here "RedGuides has NOT published offsets for this patch yet. Nothing was changed.`nTry again in a few hours (or tomorrow) with the same command."
}
if ($text -notmatch 'official offsets match') { Stop-Here 'Could not confirm that the official offsets match your client. Nothing was changed.' }
Say 'Official offsets match your client.' 'Green'
Show-MissingCoreFixes
if ($DryRun) { Say ''; Say 'Dry run complete: safe to run for real (without -DryRun).' 'Green'; exit 0 }

# ------------------------------------------------------------ 4. full rebuild
Say ''; Say 'Rebuilding everything (about 10-15 minutes) ...' 'Cyan'
$rc = Run-Rebuild @('-Sync', '-ApplyOfficial', '-Update', '-InstallDir', $InstallDir)
$text = $script:rbOut -join "`n"
if ($rc -eq 1 -or $rc -eq 255) { Stop-Here "The update stopped with an error (see above). Your install was NOT replaced.`nYour previous build is untouched." }
$partial = ($rc -ne 0)
if ($text -notmatch 'files installed, all stamped') { $partial = $true }

Say ''
if ($partial) {
    Say 'FINISHED WITH PROBLEMS: some plugins failed to build or could not be copied (listed above).' 'Yellow'
    Say 'The rest installed. Test in game; bring me the failing plugin names.' 'Yellow'
} else {
    Say 'SUCCESS: everything built, verified and installed.' 'Green'
}
Say ''; Say 'Now test in game:' 'Cyan'
Say '  - log in, zone 5+ times (include the guild lobby and hall)'
Say '  - right-click an item, run /plugin, open the chat window'
Say '  - try /nav, click the map, log in with a profile'
Say 'If it all works, save it to GitHub with:' 'Cyan'
Say ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Publish' -f $MyInvocation.MyCommand.Path)

if ($Launch) {
    Say ''; Say 'Launching MacroQuest ...' 'Cyan'
    Start-Process (Join-Path $InstallDir 'MacroQuest.exe') -WorkingDirectory $InstallDir
}
exit $(if ($partial) { 3 } else { 0 })

