<#
.SYNOPSIS
    Keep your settings and scripts the same in the RedGuides install (C:\MQNext) and your own build
    (C:\MQNext-LiveTest), so you can switch between them after a patch and back again.

.DESCRIPTION
    Default: copy C:\MQNext -> C:\MQNext-LiveTest (run before you start playing from LiveTest).
    -Back  : copy C:\MQNext-LiveTest -> C:\MQNext (run when you go back to C:\MQNext, BEFORE starting it).

    Folders: config\, lua\, macros\, modules\, resources\. Program files (exe/dll in the root and
    plugins\) are never touched: each install keeps its own.

    How it decides what to copy: after every sync it records the size and time of each file that is
    the same in both installs (settings-sync-manifest.txt in the LiveTest folder). Next time:
      * changed only on the side you copy FROM  -> copied
      * changed only on the side you copy TO    -> left alone (copy it the other way when you switch)
      * changed on BOTH sides                   -> left alone and listed as a conflict;
                                                   re-run with -Force to let the FROM side win
      * new file                                -> copied
      * deleted file                            -> nothing is ever deleted
    The very first sync copies every file that differs from C:\MQNext into LiveTest.

    Safety:
      * Every file that gets overwritten is saved first to <to>\backup-settings-<time>\.
      * Databases (*.db, -wal, -shm) are skipped while MacroQuest is running from the FROM side
        (a database copied mid-write can be corrupt). Close it and run again to finish.
      * Refuses to run while MacroQuest is running from the TO side.
      * MacroQuest.ini is merged, not copied: [Plugins] only enables plugins whose DLL exists in the TO
        install and keeps entries only the TO install has (e.g. CWTN in C:\MQNext); [Internal] and the
        launcher window name/class stay as they are in the TO install.
      * Never copied: MacroQuest_default.ini, MacroQuest_LauncherUI.ini, MQ2AutoLogin*.ini (old, logins
        are in login.db), redfetch_check_state.json.

.PARAMETER MQNext    The RedGuides install.  Default C:\MQNext
.PARAMETER LiveTest  Your own build.         Default C:\MQNext-LiveTest
.PARAMETER Back      Copy LiveTest -> MQNext instead of MQNext -> LiveTest.
.PARAMETER DryRun    Show what would be copied. Changes nothing.
.PARAMETER Force     For files changed on both sides, let the FROM side win (still backed up).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Sync-Settings.ps1 -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Sync-Settings.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\custom\Sync-Settings.ps1 -Back
#>
[CmdletBinding()]
param(
    [string]$MQNext   = 'C:\MQNext',
    [string]$LiveTest = 'C:\MQNext-LiveTest',
    [switch]$Back,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ($Back) { $Source = $LiveTest; $Dest = $MQNext;   $srcSide = 'LiveTest'; $dstSide = 'MQNext' }
else       { $Source = $MQNext;   $Dest = $LiveTest; $srcSide = 'MQNext';   $dstSide = 'LiveTest' }

$folders  = @('config', 'lua', 'macros', 'modules', 'resources')
$excluded = @('config\MacroQuest_default.ini', 'config\MacroQuest_LauncherUI.ini', 'config\MQ2AutoLogin*.ini',
              'config\redfetch_check_state.json', 'config\MacroQuest.ini')   # MacroQuest.ini is merged separately
$keepDestMQKeys = @('MacroQuestWinClassName', 'MacroQuestWinName')
$manifestFile = Join-Path $LiveTest 'settings-sync-manifest.txt'
$backupDir = Join-Path $Dest ("backup-settings-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$latin1    = [Text.Encoding]::GetEncoding(28591)   # reads/writes every byte unchanged, whatever the file's encoding

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Fail([string]$m) { Say "ERROR: $m" 'Red'; exit 1 }

function Test-InUse([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    try { $s = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $s.Close(); return $false } catch { return $true }
}
function Test-MQRunning([string]$dir) { return (Test-InUse (Join-Path $dir 'MQ2Main.dll')) -or (Test-InUse (Join-Path $dir 'MacroQuest.exe')) }
function Test-IsDatabase([string]$rel) { return $rel -match '\.(db|sqlite)(-wal|-shm)?$' }

# file state as recorded in the manifest
function Get-State($f) { return @{ Len = $f.Length; Ticks = $f.LastWriteTimeUtc.Ticks } }
function Test-SameState($a, $b) { return $a.Len -eq $b.Len -and [math]::Abs($a.Ticks - $b.Ticks) -le 20000000 }   # 2 s

function Get-Tree([string]$root) {
    $t = @{}
    foreach ($folder in $folders) {
        $dir = Join-Path $root $folder
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $rel = $f.FullName.Substring($root.Length).TrimStart('\')
            if ($excluded | Where-Object { $rel -like $_ }) { continue }
            $t[$rel] = $f
        }
    }
    return $t
}

function Read-Manifest {
    if (-not (Test-Path $manifestFile)) { return $null }
    $m = @{}
    foreach ($l in [IO.File]::ReadAllLines($manifestFile)) {
        if ($l.StartsWith('#')) { continue }
        $p = $l.Split("`t")
        if ($p.Count -eq 3) { $m[$p[0]] = @{ Len = [long]$p[1]; Ticks = [long]$p[2] } }
    }
    return $m
}
function Write-Manifest($m) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# settings sync record, last sync $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $srcSide -> $dstSide")
    foreach ($k in ($m.Keys | Sort-Object)) { $lines.Add("$k`t$($m[$k].Len)`t$($m[$k].Ticks)") }
    [IO.File]::WriteAllLines($manifestFile, $lines)
}

# ---- MacroQuest.ini merge ----------------------------------------------------
function Read-IniSections([string]$path) {
    $sections = New-Object System.Collections.ArrayList
    $cur = @{ Name = ''; Lines = New-Object System.Collections.ArrayList }
    $null = $sections.Add($cur)
    foreach ($l in [IO.File]::ReadAllLines($path, $latin1)) {
        if ($l -match '^\s*\[([^\]]+)\]\s*$') {
            $cur = @{ Name = $Matches[1]; Lines = New-Object System.Collections.ArrayList }
            $null = $sections.Add($cur)
        }
        $null = $cur.Lines.Add($l)
    }
    return $sections
}
function Get-IniKey([string]$line) { if ($line -match '^\s*([^=;#\[][^=]*?)\s*=') { return $Matches[1] } return $null }

function Get-MergedMacroQuestIni([string]$srcIni, [string]$dstIni, [string]$dstPlugins) {
    $src = Read-IniSections $srcIni
    $dst = if (Test-Path $dstIni) { Read-IniSections $dstIni } else { @() }

    $dstPluginLines = [ordered]@{}; $dstInternal = $null; $dstMQ = @{}
    foreach ($s in $dst) {
        if ($s.Name -eq 'Plugins')  { foreach ($l in $s.Lines) { $k = Get-IniKey $l; if ($k) { $dstPluginLines[$k.ToLower()] = $l } } }
        if ($s.Name -eq 'Internal') { $dstInternal = $s.Lines }
        if ($s.Name -eq 'MacroQuest') { foreach ($l in $s.Lines) { $k = Get-IniKey $l; if ($k -and $keepDestMQKeys -contains $k) { $dstMQ[$k] = $l } } }
    }

    $out = New-Object System.Collections.ArrayList
    $dropped = @(); $sawInternal = $false
    foreach ($s in $src) {
        switch ($s.Name) {
            'Plugins' {
                $seen = @{}
                foreach ($l in $s.Lines) {
                    $k = Get-IniKey $l
                    if (-not $k) { $null = $out.Add($l); continue }
                    $seen[$k.ToLower()] = $true
                    if (Test-Path (Join-Path $dstPlugins "$k.dll")) { $null = $out.Add($l) }
                    elseif ($l -match '=\s*1\s*$') { $dropped += $k }
                }
                # entries only the destination has (e.g. CWTN plugins in C:\MQNext), placed before the
                # blank lines that end the section
                $at = $out.Count
                while ($at -gt 0 -and -not $out[$at - 1].Trim()) { $at-- }
                foreach ($k in $dstPluginLines.Keys) { if (-not $seen[$k]) { $out.Insert($at, $dstPluginLines[$k]); $at++ } }
            }
            'Internal' {
                $sawInternal = $true
                if ($dstInternal) { foreach ($l in $dstInternal) { $null = $out.Add($l) } } else { foreach ($l in $s.Lines) { $null = $out.Add($l) } }
            }
            'MacroQuest' {
                foreach ($l in $s.Lines) {
                    $k = Get-IniKey $l
                    if ($k -and $dstMQ.ContainsKey($k)) { $null = $out.Add($dstMQ[$k]) } else { $null = $out.Add($l) }
                }
            }
            default { foreach ($l in $s.Lines) { $null = $out.Add($l) } }
        }
    }
    if (-not $sawInternal -and $dstInternal) { foreach ($l in $dstInternal) { $null = $out.Add($l) } }
    return @{ Lines = [string[]]$out; Dropped = $dropped }
}

# ---- 0. sanity -----------------------------------------------------------------
foreach ($d in $Source, $Dest) { if (-not (Test-Path $d)) { Fail "Folder not found: $d" } }
if ((Resolve-Path $Source).Path -eq (Resolve-Path $Dest).Path) { Fail 'MQNext and LiveTest are the same folder.' }

Say "Sync settings  $(Get-Date)" 'Cyan'
Say "  from : $Source"
Say "  to   : $Dest"

if (Test-MQRunning $Dest) { Fail "MacroQuest is running from $Dest. Close that EverQuest and its launcher first." }
$sourceRunning = Test-MQRunning $Source
if ($sourceRunning) { Say "  MacroQuest is running from ${Source}: databases will be skipped this time." 'Yellow' }

$M = Read-Manifest
$first = ($null -eq $M)
if ($first) {
    if ($Back) { Fail "No sync has been done yet. Run without -Back first (copies $MQNext -> $LiveTest)." }
    Say "  first sync: every file that differs is copied from $MQNext" 'Yellow'
    $M = @{}
}

# ---- 1. decide per file ---------------------------------------------------------
Say ''; Say 'Comparing ...' 'Cyan'
$srcTree = Get-Tree $Source
$dstTree = Get-Tree $Dest
$newM = @{}
$toCopy = New-Object System.Collections.ArrayList
$keptDest = New-Object System.Collections.ArrayList
$conflicts = New-Object System.Collections.ArrayList
$skippedDb = 0

foreach ($rel in $srcTree.Keys) {
    $fa = $srcTree[$rel]; $fb = $dstTree[$rel]; $sa = Get-State $fa
    if ($sourceRunning -and (Test-IsDatabase $rel)) { $skippedDb++; if ($M[$rel]) { $newM[$rel] = $M[$rel] }; continue }
    if ($fb -and (Test-SameState $sa (Get-State $fb))) { $newM[$rel] = $sa; continue }
    $item = [pscustomobject]@{ Rel = $rel; Src = $fa.FullName; Dst = (Join-Path $Dest $rel); Exists = [bool]$fb; State = $sa }
    if (-not $fb -or $first) { $null = $toCopy.Add($item); continue }
    $rec = $M[$rel]
    if ($rec) {
        $changedA = -not (Test-SameState $sa $rec)
        $changedB = -not (Test-SameState (Get-State $fb) $rec)
        if ($changedA -and -not $changedB) { $null = $toCopy.Add($item) }
        elseif ($changedB -and -not $changedA) { $null = $keptDest.Add($rel); $newM[$rel] = $rec }
        elseif ($Force) { $null = $toCopy.Add($item) }
        else { $null = $conflicts.Add($rel); $newM[$rel] = $rec }
    } else {
        # no record of this file being in sync: the newer copy wins
        if ($fa.LastWriteTimeUtc -gt $fb.LastWriteTimeUtc.AddSeconds(2)) { $null = $toCopy.Add($item) }
        else { $null = $keptDest.Add($rel) }
    }
}
# keep the record of files that exist only on the destination side
foreach ($rel in $M.Keys) { if (-not $srcTree.ContainsKey($rel) -and $dstTree.ContainsKey($rel) -and -not $newM.ContainsKey($rel)) { $newM[$rel] = $M[$rel] } }

# a replaced database must not keep the destination's old journal
$toRemove = New-Object System.Collections.ArrayList
foreach ($c in @($toCopy | Where-Object { $_.Rel -match '\.(db|sqlite)$' })) {
    foreach ($sfx in '-wal', '-shm') {
        if (-not (Test-Path -LiteralPath ($c.Src + $sfx)) -and (Test-Path -LiteralPath ($c.Dst + $sfx))) {
            $null = $toRemove.Add([pscustomobject]@{ Rel = $c.Rel + $sfx; Dst = $c.Dst + $sfx })
        }
    }
}

# MacroQuest.ini: each side's own copy is recorded under @MQNext / @LiveTest
$iniSrc = Join-Path $Source 'config\MacroQuest.ini'
$iniDst = Join-Path $Dest 'config\MacroQuest.ini'
$ini = $null; $iniAction = 'none'
if (Test-Path $iniSrc) {
    $iniSrcState = Get-State (Get-Item $iniSrc)
    $iniDstState = if (Test-Path $iniDst) { Get-State (Get-Item $iniDst) } else { $null }
    $mSrc = $M["@$srcSide"]; $mDst = $M["@$dstSide"]
    $changedA = -not $mSrc -or -not (Test-SameState $iniSrcState $mSrc)
    $changedB = $iniDstState -and (-not $mDst -or -not (Test-SameState $iniDstState $mDst))
    if ($first -or -not $iniDstState -or ($changedA -and -not $changedB) -or ($changedA -and $Force)) {
        $ini = Get-MergedMacroQuestIni $iniSrc $iniDst (Join-Path $Dest 'plugins')
        $old = if ($iniDstState) { [IO.File]::ReadAllLines($iniDst, $latin1) -join "`n" } else { '' }
        $iniAction = if (($ini.Lines -join "`n") -ne $old) { 'merge' } else { 'same' }
    } elseif ($changedA -and $changedB) { $iniAction = 'conflict'; $null = $conflicts.Add('config\MacroQuest.ini') }
    elseif ($changedB) { $iniAction = 'kept'; $null = $keptDest.Add('config\MacroQuest.ini') }
}

# ---- 2. report -------------------------------------------------------------------
$newCount = @($toCopy | Where-Object { -not $_.Exists }).Count
Say ("  {0} files to copy ({1} new, {2} changed){3}{4}" -f $toCopy.Count, $newCount, ($toCopy.Count - $newCount),
    $(if ($toRemove.Count) { ", $($toRemove.Count) stale database journals to remove" } else { '' }),
    $(if ($iniAction -eq 'merge') { ', MacroQuest.ini to merge' } else { '' }))
foreach ($folder in $folders) {
    $n = @($toCopy | Where-Object { $_.Rel -like "$folder\*" }).Count
    if ($n) { Say ("    {0,-10} {1}" -f $folder, $n) }
}
if ($ini -and $ini.Dropped.Count) {
    Say ("  MacroQuest.ini: plugins left out because $Dest has no DLL for them: " + (($ini.Dropped | Sort-Object) -join ', ')) 'DarkGray'
}
if ($keptDest.Count) { Say ("  {0} files are newer in {1} and were left alone (copy them the other way when you switch)." -f $keptDest.Count, $Dest) 'DarkGray' }
if ($skippedDb) { Say "  $skippedDb database files skipped (MacroQuest is running from $Source)" 'Yellow' }
if ($conflicts.Count) {
    Say ''
    Say ("{0} files were changed in BOTH installs since the last sync and were NOT copied:" -f $conflicts.Count) 'Yellow'
    foreach ($c in ($conflicts | Sort-Object | Select-Object -First 20)) { Say "    $c" 'Yellow' }
    if ($conflicts.Count -gt 20) { Say "    ... and $($conflicts.Count - 20) more" 'Yellow' }
    Say "  To let the $srcSide copies win, re-run with -Force (the $dstSide copies are backed up first)." 'Yellow'
}

if ($DryRun) {
    foreach ($c in ($toCopy | Select-Object -First 25)) { Say ("    {0} {1}" -f $(if ($c.Exists) { 'update' } else { 'new   ' }), $c.Rel) 'DarkGray' }
    if ($toCopy.Count -gt 25) { Say "    ... and $($toCopy.Count - 25) more" 'DarkGray' }
    Say ''; Say 'Dry run: nothing was copied.' 'Green'
    exit 0
}

# ---- 3. back up + copy ----------------------------------------------------------
function Backup-File([string]$dst, [string]$rel) {
    $b = Join-Path $backupDir $rel
    $null = New-Item -ItemType Directory -Force (Split-Path $b -Parent)
    Copy-Item -LiteralPath $dst $b -Force
}

$failed = @(); $done = 0
foreach ($c in $toCopy) {
    try {
        if ($c.Exists) { Backup-File $c.Dst $c.Rel }
        else { $null = New-Item -ItemType Directory -Force (Split-Path $c.Dst -Parent) }
        Copy-Item -LiteralPath $c.Src $c.Dst -Force
        $newM[$c.Rel] = $c.State
        $done++
    } catch {
        $failed += "$($c.Rel) ($($_.Exception.Message))"
        if ($M[$c.Rel]) { $newM[$c.Rel] = $M[$c.Rel] }
    }
}
foreach ($r in $toRemove) {
    try { Backup-File $r.Dst $r.Rel; Remove-Item -LiteralPath $r.Dst -Force } catch { $failed += "$($r.Rel) ($($_.Exception.Message))" }
}

switch ($iniAction) {
    'merge' {
        try {
            if (Test-Path $iniDst) { Backup-File $iniDst 'config\MacroQuest.ini' }
            [IO.File]::WriteAllLines($iniDst, $ini.Lines, $latin1)
            Say '  merged config\MacroQuest.ini' 'Green'
            $newM["@$srcSide"] = $iniSrcState; $newM["@$dstSide"] = Get-State (Get-Item $iniDst)
        } catch { $failed += "config\MacroQuest.ini ($($_.Exception.Message))" }
    }
    'same' { $newM["@$srcSide"] = $iniSrcState; $newM["@$dstSide"] = $iniDstState }
    default { foreach ($k in "@$srcSide", "@$dstSide") { if ($M[$k]) { $newM[$k] = $M[$k] } } }
}

Write-Manifest $newM

Say ''
Say "Copied $done files from $Source to $Dest." 'Green'
if (Test-Path $backupDir) { Say "Overwritten files were saved in $backupDir" 'Gray' }
if ($skippedDb) { Say "Databases were skipped. Close MacroQuest in $Source and run this again to copy them." 'Yellow' }
if ($failed.Count) {
    Say ("{0} files could not be copied:" -f $failed.Count) 'Yellow'
    foreach ($f in ($failed | Select-Object -First 15)) { Say "    $f" 'Yellow' }
}
if ($conflicts.Count) { exit 2 }
if ($failed.Count) { exit 3 }
exit 0
