<#
.SYNOPSIS
    Re-create the plugin source folders under plugins\ from plugin-commits.txt.

.DESCRIPTION
    plugin-commits.txt (written by Rebuild-Plugins.ps1) lists, for every plugin repository:
        <folder> | <commit sha> | <remote url>
    This clones any that are missing into plugins\ and checks out the exact commit that was built,
    so a new machine (or a wiped plugins\ folder) gets the same plugin sources back.
    Existing folders are left alone unless -Force is given (then they are checked out at the recorded commit).

.PARAMETER Only    Restore only folders matching these names (wildcards ok).
.PARAMETER Force   Also check out the recorded commit in folders that already exist (they must have no local edits).
.PARAMETER DryRun  Show what would be done.

.EXAMPLE
    .\Restore-Plugins.ps1 -DryRun
    .\Restore-Plugins.ps1
    .\Restore-Plugins.ps1 -Only MQ2Nav -Force
#>
[CmdletBinding()]
param([string[]]$Only, [switch]$Force, [switch]$DryRun)

$ErrorActionPreference = 'Stop'

# powershell.exe -File passes "-Only A,B" as ONE string "A,B"; accept both forms.
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$repo = $PSScriptRoot
while ($repo -and -not (Test-Path (Join-Path $repo 'src\MacroQuest.sln'))) { $repo = Split-Path -Parent $repo }
if (-not $repo) { throw "Could not find the openvanilla repo root above $PSScriptRoot." }
$pluginsDir = Join-Path $repo 'plugins'
$recordFile = Join-Path $PSScriptRoot 'plugin-commits.txt'
if (-not (Test-Path $recordFile)) { throw "Missing $recordFile" }

function Invoke-Git([string]$dir, [string[]]$gitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & git -C $dir @gitArgs 2>&1 | ForEach-Object { "$_" }; $ok = ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $prev }
    return @{ Ok = $ok; Out = ($out -join "`n") }
}

$entries = foreach ($line in Get-Content $recordFile) {
    if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
    $p = $line -split '\s*\|\s*'
    if ($p.Count -ge 3) { [pscustomobject]@{ Name = $p[0]; Sha = $p[1]; Url = $p[2] } }
}
if ($Only) { $entries = $entries | Where-Object { $n = $_.Name; $Only | Where-Object { $n -like $_ } } }

New-Item -ItemType Directory -Force $pluginsDir | Out-Null
$ok = 0; $skipped = 0; $failed = @()
foreach ($e in $entries) {
    $dir = Join-Path $pluginsDir $e.Name
    $exists = Test-Path (Join-Path $dir '.git')
    if ($exists -and -not $Force) { Write-Host ("  {0,-20} already present, skipped" -f $e.Name) -ForegroundColor DarkGray; $skipped++; continue }
    if ($DryRun) { Write-Host ("  {0,-20} would {1} @ {2}" -f $e.Name, $(if ($exists) { 'check out' } else { 'clone' }), $e.Sha.Substring(0, 8)) -ForegroundColor Yellow; continue }

    if (-not $exists) {
        $c = Invoke-Git $pluginsDir @('clone', '--recurse-submodules', $e.Url, $e.Name)
        if (-not $c.Ok) { Write-Host ("  {0,-20} CLONE FAILED: {1}" -f $e.Name, $c.Out.Split("`n")[0]) -ForegroundColor Red; $failed += $e.Name; continue }
    } elseif ((Invoke-Git $dir @('status', '--porcelain')).Out.Trim()) {
        Write-Host ("  {0,-20} has local changes, NOT touched" -f $e.Name) -ForegroundColor Yellow; $skipped++; continue
    }
    $co = Invoke-Git $dir @('checkout', '--detach', $e.Sha)
    if (-not $co.Ok) { $null = Invoke-Git $dir @('fetch', '--all'); $co = Invoke-Git $dir @('checkout', '--detach', $e.Sha) }
    if (-not $co.Ok) { Write-Host ("  {0,-20} could not check out {1}: {2}" -f $e.Name, $e.Sha.Substring(0, 8), $co.Out.Split("`n")[0]) -ForegroundColor Red; $failed += $e.Name; continue }
    $null = Invoke-Git $dir @('submodule', 'update', '--init', '--recursive')
    Write-Host ("  {0,-20} at {1}" -f $e.Name, $e.Sha.Substring(0, 8)) -ForegroundColor Green
    $ok++
}
Write-Host ''
if ($DryRun) { Write-Host 'Dry run: nothing cloned or changed.' -ForegroundColor Green; exit 0 }
Write-Host ("Restored/updated: {0}   skipped: {1}   failed: {2}" -f $ok, $skipped, $failed.Count)
if ($failed.Count) { Write-Host ("Failed: " + ($failed -join ', ')) -ForegroundColor Red; exit 3 }
Write-Host "Next: run Rebuild-Plugins.ps1 to build them." -ForegroundColor Cyan
