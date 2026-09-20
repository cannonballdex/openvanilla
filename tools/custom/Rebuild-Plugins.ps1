<#
.SYNOPSIS
    Rebuild MacroQuest core and every custom plugin in plugins\ after an EverQuest patch,
    verify each DLL is stamped for the right client, and install into your test folder.

.DESCRIPTION
    Steps:
      1. Refuse to run while eqgame.exe / MacroQuest.exe are running (their DLLs are locked).
      2. Read the client version that eqlib expects (src\eqlib\include\eqlib\offsets\eqgame.h) and
         check it against the real eqgame.exe. If they differ, eqgame.h is out of date: STOP.
      3. Build src\MacroQuest.sln (core + built-in plugins), unless -SkipCore.
      4. Find every plugin project under plugins\ (any .vcxproj that imports src\Plugin.props) and build it.
      5. Check each built DLL contains the expected version stamp. A DLL with the wrong stamp is NOT installed.
      6. Back up what is in <InstallDir>, then copy the new files in.

    Address-only fixes (edits to eqgame.h and nothing else) only need eqlib.dll / MQ2Main.dll replaced;
    use -CoreOnly for that. A new client patch needs everything rebuilt (default).

.PARAMETER InstallDir   Where MacroQuest is installed for testing.   Default: C:\MQNext-LiveTest
.PARAMETER EQDir        Your EverQuest folder.                       Default: C:\EverQuest
.PARAMETER SkipCore     Do not rebuild/copy core, only plugins in plugins\.
.PARAMETER CoreOnly     Rebuild/copy core only (address-only fixes).
.PARAMETER Only         Build only plugins whose project name matches one of these (e.g. MQ2Nav, MQ2DanNet).
.PARAMETER Update       Before building, run "git pull --ff-only" (and update submodules) in each plugin's git
                        repository under plugins\ and report which ones changed. Repos with local edits are
                        skipped. With -Only, only the repos that contain a matching plugin are updated.
                        Off by default: your plugins stay pinned to the commit you already built and tested.
.PARAMETER DryRun       Show what would happen. Builds nothing, copies nothing, pulls nothing.

.EXAMPLE
    .\Rebuild-Plugins.ps1 -DryRun
    .\Rebuild-Plugins.ps1
    .\Rebuild-Plugins.ps1 -CoreOnly
    .\Rebuild-Plugins.ps1 -SkipCore -Only MQ2Nav
    .\Rebuild-Plugins.ps1 -Update
    .\Rebuild-Plugins.ps1 -Update -SkipCore -Only MQ2Nav
#>
[CmdletBinding()]
param(
    [string]$InstallDir    = 'C:\MQNext-LiveTest',
    [string]$EQDir         = 'C:\EverQuest',
    [string]$Configuration = 'Release',
    [string]$Platform      = 'x64',
    [switch]$SkipCore,
    [switch]$CoreOnly,
    [string[]]$Only,
    [switch]$Update,
    [switch]$Sync,
    [switch]$ApplyOfficial,
    [string]$EqlibRepo     = 'https://github.com/redguides/eqlib.git',
    [string]$EqlibBranch   = 'live',
    [switch]$SkipVerify,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# powershell.exe -File passes "-Only A,B" as ONE string "A,B"; accept both forms.
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# ---- locations -------------------------------------------------------------
# Find the repo root by walking up from wherever this script lives until src\MacroQuest.sln is found,
# so it works from tools\custom\ (tracked) as well as from plugins\.
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path (Join-Path $repo 'src\MacroQuest.sln'))) { $repo = Split-Path -Parent $repo }
if (-not $repo) { throw "Could not find the openvanilla repo root (looked upward from $PSScriptRoot for src\MacroQuest.sln)." }
$pluginsDir= Join-Path $repo 'plugins'
$solution  = Join-Path $repo 'src\MacroQuest.sln'
$header    = Join-Path $repo 'src\eqlib\include\eqlib\offsets\eqgame.h'
$outDir    = Join-Path $repo ("build\bin\{0}" -f $Configuration.ToLower())
$outPlugins= Join-Path $outDir 'plugins'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $InstallDir "backup-$stamp"
$logFile   = Join-Path $pluginsDir "rebuild-$stamp.log"      # plugins\ is git-ignored, so logs never get committed

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    if (-not $DryRun) { Add-Content -Path $logFile -Value $msg -ErrorAction SilentlyContinue }
}
function Fail([string]$msg) { Say "ERROR: $msg" 'Red'; exit 1 }

function Find-MSBuild {
    # Prefer the Visual Studio 2022 toolchain that the projects target (v143), so every build
    # uses the same compiler. Only fall back to whatever vswhere finds if 2022 is not installed.
    foreach ($c in @(
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe')) {
        if (Test-Path $c) { return $c }
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
        if ($p -and (Test-Path $p)) { Say "WARNING: VS2022 not found, using $p" 'Yellow'; return $p }
    }
    Fail 'MSBuild.exe not found. Install Visual Studio 2022 Build Tools (C++ workload).'
}

# does the binary contain this ASCII text?
function Test-FileHasText([string]$path, [string]$text) {
    $bytes = [IO.File]::ReadAllBytes($path)
    return [Text.Encoding]::ASCII.GetString($bytes).Contains($text)
}

# Runs a git command, never throws, returns @{ Ok; Out }.
function Invoke-Git([string]$dir, [string[]]$gitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & git -C $dir @gitArgs 2>&1 | ForEach-Object { "$_" }; $ok = ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $prev }
    return @{ Ok = $ok; Out = ($out -join "`n") }
}

# Pull the version stamp out of an eqgame.h text.
function Get-HeaderVersion([string]$text) {
    $d = [regex]::Match($text, '#define\s+__ExpectedVersionDate\s+"([^"]+)"')
    $t = [regex]::Match($text, '#define\s+__ExpectedVersionTime\s+"([^"]+)"')
    if ($d.Success -and $t.Success) { return @{ Date = $d.Groups[1].Value; Time = $t.Groups[1].Value } }
    return $null
}

# Sanity-check eqgame.h against the real client. In this client every function begins after CC padding
# (or right after a ret). An entry that does not is almost always an address pointing INTO a function.
# It cannot catch an address that points at a different, valid function, so it is a smoke test only.
function Test-OffsetSanity([string]$headerText, [string]$exePath) {
    $b = [IO.File]::ReadAllBytes($exePath)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $imageBase = [BitConverter]::ToUInt64($b, $pe + 24 + 24)
    $so = $pe + 24 + $optSize
    $textRva = 0; $textRaw = 0; $textLen = 0
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = $so + 40 * $i
        if ([Text.Encoding]::ASCII.GetString($b, $o, 8).TrimEnd([char]0) -eq '.text') {
            $textRva = [BitConverter]::ToUInt32($b, $o + 12); $textLen = [BitConverter]::ToUInt32($b, $o + 8); $textRaw = [BitConverter]::ToUInt32($b, $o + 20)
        }
    }
    $bad = @(); $total = 0
    foreach ($m in [regex]::Matches($headerText, '#define\s+(\w+)_x\s+0x([0-9A-Fa-f]+)')) {
        $rva = [Convert]::ToUInt64($m.Groups[2].Value, 16) - $imageBase
        if ($rva -lt $textRva -or $rva -ge ($textRva + $textLen)) { continue }     # data, not code
        $total++
        $prev = $b[$textRaw + ($rva - $textRva) - 1]
        if ($prev -ne 0xCC -and $prev -ne 0xC3) { $bad += $m.Groups[1].Value }
    }
    return @{ Total = $total; Bad = $bad }
}

# ---- 0. sanity -------------------------------------------------------------
foreach ($p in @($solution, $header)) { if (-not (Test-Path $p)) { Fail "Missing: $p" } }
if (-not (Test-Path $InstallDir)) { Fail "InstallDir not found: $InstallDir" }
if ($SkipCore -and $CoreOnly) { Fail '-SkipCore and -CoreOnly cannot be combined.' }

Say "Rebuild-Plugins  $(Get-Date)" 'Cyan'
Say "  repo      : $repo"
Say "  install   : $InstallDir"
Say "  eq client : $EQDir"

$running = Get-Process eqgame, MacroQuest -ErrorAction SilentlyContinue
if ($running -and -not $DryRun) {
    Fail ("Close these first (their DLLs are locked): " + (($running | ForEach-Object { "$($_.Name) [$($_.Id)]" }) -join ', '))
}

# ---- 0b. optional: check RedGuides' official eqlib for this client ----------
# RedGuides publishes the offsets for every EQ patch in redguides/eqlib (branch 'live').
# -Sync     : fetch it and report whether it matches the client you have installed (changes nothing).
# -ApplyOfficial (with -Sync) : switch src\eqlib to a local branch 'official-<branch>' at that commit.
if ($Sync) {
    $eqlibDir = Join-Path $repo 'src\eqlib'
    Say ''; Say "Checking official eqlib ($EqlibRepo, branch '$EqlibBranch') ..." 'Cyan'
    if (-not (Invoke-Git $eqlibDir @('remote', 'get-url', 'redguides')).Ok) {
        if ($DryRun) { Say '  (would add git remote "redguides")' 'DarkYellow' }
        else { $null = Invoke-Git $eqlibDir @('remote', 'add', 'redguides', $EqlibRepo) }
    }
    $fetch = if ($DryRun) { Invoke-Git $eqlibDir @('fetch', $EqlibRepo, "${EqlibBranch}:refs/remotes/redguides/$EqlibBranch") }
             else         { Invoke-Git $eqlibDir @('fetch', 'redguides', $EqlibBranch) }
    if (-not $fetch.Ok) { Fail "Could not fetch official eqlib: $($fetch.Out)" }
    $ref = "redguides/$EqlibBranch"
    $offText = (Invoke-Git $eqlibDir @('show', "${ref}:include/eqlib/offsets/eqgame.h")).Out
    $offVer = Get-HeaderVersion $offText
    if (-not $offVer) { Fail "Could not read the client version from $ref" }
    $offStamp = "$($offVer.Date) $($offVer.Time)"
    $eqExe0 = Join-Path $EQDir 'eqgame.exe'
    $clientOk = (Test-Path $eqExe0) -and (Test-FileHasText $eqExe0 $offVer.Date) -and (Test-FileHasText $eqExe0 $offVer.Time)
    $head  = (Invoke-Git $eqlibDir @('rev-parse', '--short', 'HEAD')).Out.Trim()
    $tip   = (Invoke-Git $eqlibDir @('rev-parse', '--short', $ref)).Out.Trim()
    $ahead = (Invoke-Git $eqlibDir @('rev-list', '--count', "HEAD..$ref")).Out.Trim()
    Say ("  official {0} : {1}   (commit {2}, {3} commits not in your eqlib)" -f $ref, $offStamp, $tip, $ahead)
    Say ("  your eqlib HEAD    : {0}" -f $head)
    if ($clientOk) { Say "  official offsets match the eqgame.exe you have installed." 'Green' }
    else { Say "  official offsets are NOT for your installed client yet (RedGuides has not published it). Wait, or update offsets by hand." 'Yellow' }

    if ($ApplyOfficial) {
        if ($DryRun)      { Say '  (dry run: would switch src\eqlib to the official commit)' 'DarkYellow' }
        elseif (-not $clientOk) { Fail 'Refusing -ApplyOfficial: the official offsets do not match your installed client.' }
        elseif ((Invoke-Git $eqlibDir @('status', '--porcelain')).Out.Trim()) { Fail 'src\eqlib has uncommitted changes. Commit or stash them, then re-run.' }
        else {
            $br = "official-$EqlibBranch"
            $sw = Invoke-Git $eqlibDir @('checkout', '-B', $br, $ref)
            if (-not $sw.Ok) { Fail "Could not switch src\eqlib: $($sw.Out)" }
            Say "  src\eqlib is now on branch '$br' at $tip. Your previous branch is untouched (git -C src\eqlib checkout <name> to go back)." 'Green'
            Say '  NOTE: the main repo now shows src\eqlib as modified. Commit it when you are happy with the result.' 'Yellow'
        }
    } elseif ($clientOk -and [int]$ahead -gt 0) {
        Say '  To use it: re-run with -Sync -ApplyOfficial' 'Yellow'
    }
}

# ---- 1. expected client version -------------------------------------------
$h = Get-Content $header -Raw
$hv = Get-HeaderVersion $h
if (-not $hv) { Fail "Could not read __ExpectedVersionDate/Time from $header" }
$dm = [pscustomobject]@{ Groups = @($null, [pscustomobject]@{ Value = $hv.Date }) }
$tm = [pscustomobject]@{ Groups = @($null, [pscustomobject]@{ Value = $hv.Time }) }
$expected = "$($hv.Date) $($hv.Time)"
Say "  expects   : $expected" 'Yellow'

$eqExe = Join-Path $EQDir 'eqgame.exe'
if (Test-Path $eqExe) {
    # eqgame.exe keeps the build date and time as two separate strings (our DLLs store them joined).
    if ((Test-FileHasText $eqExe $dm.Groups[1].Value) -and (Test-FileHasText $eqExe $tm.Groups[1].Value)) {
        Say "  eqgame.exe: matches ($expected)" 'Green'
    } else {
        Fail ("eqgame.exe in $EQDir does NOT contain '$expected'. eqgame.h is for a different client than the one you have installed. " +
              "Update src\eqlib (offsets and __ExpectedVersion*) for the new patch before rebuilding plugins.")
    }
} else {
    Say "  (no eqgame.exe at $eqExe, skipping client check)" 'DarkYellow'
}

# ---- 1b. smoke-test the offsets against the real client --------------------
# Known-legitimate exceptions in the Sep 17 2026 client (patch points / functions after a jump table).
$knownOddEntries = @('__ThrottleFrameRate', '__ThrottleFrameRateEnd', 'CEverQuest__DoPercentConvert', 'CSidlManagerBase__CreateXWndFromTemplate1')
if (-not $SkipVerify -and (Test-Path $eqExe)) {
    $san = Test-OffsetSanity $h $eqExe
    $unexpected = @($san.Bad | Where-Object { $_ -notin $knownOddEntries })
    if ($unexpected.Count -eq 0) {
        Say ("  offsets   : {0} code entries checked against eqgame.exe, all start on a function boundary" -f $san.Total) 'Green'
    } else {
        Say ("  WARNING   : {0} of {1} eqgame.h code entries do NOT start on a function boundary. Their addresses probably point into the middle of a function and will misbehave:" -f $unexpected.Count, $san.Total) 'Red'
        Say ("              " + (($unexpected | Select-Object -First 12) -join ', ') + $(if ($unexpected.Count -gt 12) { ' ...' } else { '' })) 'Red'
        Say '              (Run with -Sync to compare against the official RedGuides offsets.)' 'Yellow'
    }
}

# ---- 2. what will be built -------------------------------------------------
function Get-PluginProjects {
    if ($CoreOnly) { return @() }
    $found = Get-ChildItem $pluginsDir -Recurse -Filter *.vcxproj -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content $_.FullName -Raw) -match 'src\\Plugin\.props' } |
        Sort-Object FullName
    if ($Only) {
        $found = $found | Where-Object { $n = $_.BaseName; $Only | Where-Object { $n -like $_ } }
    }
    return @($found)
}

# The git repository (a top-level folder under plugins\) that a project lives in.
function Get-RepoName($project) { return $project.FullName.Substring($pluginsDir.Length + 1).Split('\')[0] }

$plugProjects = Get-PluginProjects

Say ''
Say 'Plan:' 'Cyan'
if (-not $SkipCore) { Say "  core      : $solution" }
if ($plugProjects.Count -eq 0 -and -not $CoreOnly) { Say '  plugins   : (none found under plugins\)' 'DarkYellow' }
foreach ($pp in $plugProjects) { Say ("  plugin    : {0}   ({1})" -f $pp.BaseName, $pp.FullName.Replace($pluginsDir + '\', '')) }

$updateRepos = @($plugProjects | ForEach-Object { Get-RepoName $_ } | Sort-Object -Unique |
    Where-Object { Test-Path (Join-Path $pluginsDir "$_\.git") })
if ($Update) { Say ("  update    : git pull --ff-only in: " + $(if ($updateRepos.Count) { $updateRepos -join ', ' } else { '(no git repos found)' })) 'Yellow' }

if ($DryRun) { Say ''; Say 'Dry run: nothing built, copied or pulled.' 'Green'; exit 0 }

# ---- 2b. optional: update plugin sources ----------------------------------
if ($Update -and $updateRepos.Count) {
    Say ''; Say 'Updating plugin sources ...' 'Cyan'
    $changed = @(); $skipped = @(); $updFailed = @()
    foreach ($name in $updateRepos) {
        $dir = Join-Path $pluginsDir $name
        $before = (Invoke-Git $dir @('rev-parse', '--short', 'HEAD')).Out.Trim()
        $dirty  = (Invoke-Git $dir @('status', '--porcelain')).Out.Trim()
        if ($dirty) { Say "  $name : has local changes, NOT updated" 'Yellow'; $skipped += $name; continue }
        $pull = Invoke-Git $dir @('pull', '--ff-only')
        if (-not $pull.Ok) { Say "  $name : pull failed ($($pull.Out.Split("`n")[0]))" 'Red'; $updFailed += $name; continue }
        $null = Invoke-Git $dir @('submodule', 'update', '--init', '--recursive')
        $after = (Invoke-Git $dir @('rev-parse', '--short', 'HEAD')).Out.Trim()
        if ($before -ne $after) { Say "  $name : $before -> $after" 'Green'; $changed += $name } else { Say "  $name : already up to date ($after)" }
    }
    Say ("  updated: {0}   unchanged: {1}   skipped(local edits): {2}   failed: {3}" -f $changed.Count, ($updateRepos.Count - $changed.Count - $skipped.Count - $updFailed.Count), $skipped.Count, $updFailed.Count)
    # a pull can add or remove projects, so look again
    $plugProjects = Get-PluginProjects
}

$msbuild = Find-MSBuild
Say ''; Say "MSBuild: $msbuild"
$msArgs = @("/m", "/p:Configuration=$Configuration", "/p:Platform=$Platform", "/v:minimal", "/nologo")

function Invoke-Build([string]$project) {
    Say "Building $(Split-Path $project -Leaf) ..." 'Cyan'
    & $msbuild $project @msArgs 2>&1 | ForEach-Object { Add-Content $logFile $_; $_ } | Select-String -Pattern 'error|warning MSB' | ForEach-Object { Say "  $($_.Line)" 'Red' }
    return ($LASTEXITCODE -eq 0)
}

# ---- 3. build --------------------------------------------------------------
# Core must build. A single failing plugin must NOT stop the others.
if (-not $SkipCore) {
    if (-not (Invoke-Build $solution)) { Fail "Core build failed (see $logFile)" }
}
$buildFailed = @()
$built = @()
foreach ($pp in $plugProjects) {
    if (Invoke-Build $pp.FullName) { $built += $pp } else { $buildFailed += $pp.BaseName; Say "  -> $($pp.BaseName) FAILED to build, continuing with the rest" 'Red' }
}
$plugProjects = $built

# ---- 4. verify + collect files to install ----------------------------------
$toInstall = @()   # objects: Source, Dest

if (-not $SkipCore) {
    foreach ($f in 'eqlib.dll', 'MQ2Main.dll', 'MacroQuest.exe', 'Actors.exe', 'imgui-64.dll') {
        $src = Join-Path $outDir $f
        if (-not (Test-Path $src)) { continue }
        # Only MQ2Main.dll (and plugins) carry the joined version stamp; eqlib.dll, the launcher
        # and imgui do not, so they cannot be checked this way.
        if ($f -eq 'MQ2Main.dll' -and -not (Test-FileHasText $src $expected)) {
            Fail "$f is not stamped '$expected' - refusing to install."
        }
        $toInstall += [pscustomobject]@{ Name = $f; Source = $src; Dest = (Join-Path $InstallDir $f) }
    }
    # built-in plugins: only those already present in the install, and not ones that have their own
    # project under plugins\ (those are installed below, so listing them here would copy them twice)
    $customNames = @($plugProjects | ForEach-Object { $_.BaseName + '.dll' })
    foreach ($d in Get-ChildItem (Join-Path $InstallDir 'plugins') -Filter *.dll -ErrorAction SilentlyContinue) {
        if ($customNames -contains $d.Name) { continue }
        $src = Join-Path $outPlugins $d.Name
        if (Test-Path $src) {
            if (-not (Test-FileHasText $src $expected)) { Fail "plugins\$($d.Name) is not stamped '$expected' - refusing to install." }
            $toInstall += [pscustomobject]@{ Name = "plugins\$($d.Name)"; Source = $src; Dest = $d.FullName }
        }
    }
}

foreach ($pp in $plugProjects) {
    $dll = Join-Path $outPlugins ($pp.BaseName + '.dll')
    if (-not (Test-Path $dll)) { Say "  no DLL produced for $($pp.BaseName) (not a plugin? skipped)" 'DarkYellow'; continue }
    if (-not (Test-FileHasText $dll $expected)) { Fail "$($pp.BaseName).dll is not stamped '$expected' - refusing to install." }
    $toInstall += [pscustomobject]@{ Name = "plugins\$($pp.BaseName).dll"; Source = $dll; Dest = (Join-Path $InstallDir "plugins\$($pp.BaseName).dll") }
}

# Safeguard: never install the same destination file twice.
$toInstall = @($toInstall | Group-Object { $_.Dest.ToLower() } | ForEach-Object { $_.Group | Select-Object -Last 1 })

if ($toInstall.Count -eq 0) { Fail 'Nothing to install.' }

# ---- 5. back up + install --------------------------------------------------
Say ''; Say "Installing to $InstallDir  (backup: $backupDir)" 'Cyan'
$null = New-Item -ItemType Directory -Force (Join-Path $backupDir 'plugins')
$failed = @()
foreach ($i in $toInstall) {
    try {
        if (Test-Path $i.Dest) { Copy-Item $i.Dest (Join-Path $backupDir $i.Name) -Force }
        Copy-Item $i.Source $i.Dest -Force
        Say ("  installed  {0}" -f $i.Name) 'Green'
    } catch {
        $failed += $i.Name
        Say ("  FAILED     {0}  ({1})" -f $i.Name, $_.Exception.Message) 'Red'
    }
}

# Record exactly which source each installed plugin was built from (for reproducible rebuilds).
# Only when plugins were actually built: a -CoreOnly run must not touch this tracked file.
if ($plugProjects.Count -gt 0) { try {
    # Merge into the existing record: a partial run (-Only / -SkipCore) must only refresh the plugins it built.
    $commitFile = Join-Path $PSScriptRoot 'plugin-commits.txt'   # next to this script, so it is tracked and backed up
    $record = @{}
    if (Test-Path $commitFile) {
        foreach ($l in Get-Content $commitFile) {
            if ($l -match '^\s*#' -or -not $l.Trim()) { continue }
            $p = $l -split '\s*\|\s*'
            if ($p.Count -ge 3) { $record[$p[0]] = $l }
        }
    }
    foreach ($name in @($plugProjects | ForEach-Object { Get-RepoName $_ } | Sort-Object -Unique)) {
        $dir = Join-Path $pluginsDir $name
        if (Test-Path (Join-Path $dir '.git')) {
            $sha = (Invoke-Git $dir @('rev-parse', 'HEAD')).Out.Trim()
            $url = (Invoke-Git $dir @('remote', 'get-url', 'origin')).Out.Trim()
            $record[$name] = "$name | $sha | $url"
        }
    }
    $lines = @("# Last updated $(Get-Date -Format 'yyyy-MM-dd HH:mm'); built for client '$expected'", '# repo folder | commit | remote')
    $lines += ($record.Keys | Sort-Object | ForEach-Object { $record[$_] })
    Set-Content -Path $commitFile -Value $lines -Encoding UTF8
    Say "Recorded plugin source commits in $commitFile" 'DarkGray'
} catch { Say "  (could not write plugin-commits.txt: $($_.Exception.Message))" 'DarkYellow' } }

Say ''
if ($buildFailed.Count) {
    Say ("These plugins FAILED to build and were not installed: " + ($buildFailed -join ', ')) 'Red'
    Say "  (errors are in $logFile - search it for the plugin name)" 'Yellow'
}
if ($failed.Count) {
    Say ("Not installed (copy failed): " + ($failed -join ', ')) 'Yellow'
    Say 'Files that are still locked usually belong to a process that has not exited; close it and re-run.' 'Yellow'
}
if ($buildFailed.Count -or $failed.Count) {
    Say "$($toInstall.Count - $failed.Count) other files were installed, stamped '$expected'." 'Green'
    Say "Undo:  copy the files from $backupDir back over $InstallDir." 'Gray'
    exit 3
}
Say "Done. $($toInstall.Count) files installed, all stamped '$expected'." 'Green'
Say "Undo:  copy the files from $backupDir back over $InstallDir." 'Gray'
exit 0
