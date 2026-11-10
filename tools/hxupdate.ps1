# HX Remote auto-update for Windows (ASCII only, no secrets in this file).
# Installed by tools/i.ps1 to "C:\Program Files\HX-Remote-Updater\hxupdate.ps1" and run as SYSTEM
# by the scheduled task "HX Remote Update" (daily 03:30 and 10 minutes after startup).
# It finds the newest complete hx-* build of hydroxpand/hx-remote (a release that has SHA256SUMS),
# and when that is newer than C:\ProgramData\HX-Remote\build.txt and nobody is connected right now,
# downloads the Windows exe, checks its SHA-256 against SHA256SUMS and reinstalls silently.
# Settings, ID and password survive a reinstall. Log: C:\ProgramData\HX-Remote\update.log
# It also deletes session recordings (C:\ProgramData\HX-Remote\recording) older than 30 days.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repo = "hydroxpand/hx-remote"
$dataDir = Join-Path $env:ProgramData "HX-Remote"
$mark = Join-Path $dataDir "build.txt"
$log = Join-Path $dataDir "update.log"
$app = "C:\Program Files\HX-Remote\HX-Remote.exe"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
function L($m) { ((Get-Date -Format s) + "  " + $m) | Out-File -FilePath $log -Append -Encoding ascii }
function TagVer($t) {
  if ($t -match '^hx-(\d+)\.(\d+)\.(\d+)-(\d+)$') { return [version]("{0}.{1}.{2}.{3}" -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]) }
  return $null
}
# Housekeeping first (runs even when there is no update): session recordings are kept 30 days,
# 7 days when C: has less than 20 GB free.
try {
  $rec = Join-Path $dataDir "recording"
  if (Test-Path $rec) {
    $freeGB = [int]((Get-PSDrive C).Free / 1GB)
    $days = if ($freeGB -lt 20) { 7 } else { 30 }
    $old = Get-ChildItem $rec -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$days) }
    if ($old) {
      $mb = [int](($old | Measure-Object Length -Sum).Sum / 1MB)
      $old | Remove-Item -Force -ErrorAction SilentlyContinue
      L ("removed " + @($old).Count + " recordings older than " + $days + " days (" + $mb + " MB)")
    }
  }
} catch { L ("recording cleanup error: " + $_.Exception.Message) }
try {
  if ((Test-Path $log) -and ((Get-Item $log).Length -gt 200KB)) { Remove-Item $log -Force }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $h = @{ "User-Agent" = "hx-remote-updater" }
  $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=20" -Headers $h -UseBasicParsing
  $best = $null; $bestV = $null
  foreach ($r in $rels) {
    if ($r.draft) { continue }
    $v = TagVer $r.tag_name
    if (-not $v) { continue }
    $exe = $r.assets | Where-Object { $_.name -like "*x86_64.exe" } | Select-Object -First 1
    $sums = $r.assets | Where-Object { $_.name -eq "SHA256SUMS" } | Select-Object -First 1
    if (-not $exe -or -not $sums) { continue }   # build not finished or older release without checksums
    if (-not $bestV -or $v -gt $bestV) { $best = @{ tag = $r.tag_name; exe = $exe; sums = $sums }; $bestV = $v }
  }
  if (-not $best) { L "no complete release found"; exit 0 }
  $cur = ""
  if (Test-Path $mark) { $cur = ([string](Get-Content $mark | Select-Object -First 1)).Trim() }
  $curV = TagVer $cur
  if ($curV -and ($bestV -le $curV)) { exit 0 }   # up to date; no log line, keeps the log small
  # never pull the rug from under a live session (--cm is the connection manager of a session)
  # "update now" button in the app drops this flag: do not wait for the session to end
  $forceFile = Join-Path $dataDir "force-update"
  $force = Test-Path $forceFile
  if ($force) { Remove-Item $forceFile -Force -ErrorAction SilentlyContinue }
  $busy = Get-CimInstance Win32_Process -Filter "Name='HX-Remote.exe'" | Where-Object { $_.CommandLine -like "*--cm*" }
  if ($busy -and -not $force) { L ("update " + $cur + " -> " + $best.tag + " postponed: session in progress"); exit 0 }
  $f = Join-Path $env:TEMP "hx-remote-update.exe"
  Invoke-WebRequest -Uri $best.exe.browser_download_url -OutFile $f -UseBasicParsing -Headers $h
  $sf = Join-Path $env:TEMP "hx-remote-SHA256SUMS"
  Invoke-WebRequest -Uri $best.sums.browser_download_url -OutFile $sf -UseBasicParsing -Headers $h
  $line = Get-Content $sf | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($best.exe.name) + '\s*$') } | Select-Object -First 1
  if (-not $line) { L ("no checksum for " + $best.exe.name + " in " + $best.tag); exit 1 }
  $want = (($line.Trim()) -split '\s+')[0].ToLower()
  $got = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
  if ($got -ne $want) { L ("checksum mismatch for " + $best.tag + ", not installing"); Remove-Item $f -Force; exit 1 }
  L ("updating " + $(if ($cur) { $cur } else { "unknown build" }) + " -> " + $best.tag)
  $old = $null
  if (Test-Path $app) { $old = (Get-Item $app).LastWriteTimeUtc }
  Start-Process -FilePath $f -ArgumentList "--silent-install"
  $ok = $false
  for ($i = 0; $i -lt 48; $i++) {
    Start-Sleep -Seconds 5
    $okExe = (Test-Path $app) -and ((-not $old) -or ((Get-Item $app).LastWriteTimeUtc -ne $old))
    $s = Get-Service -Name "HX-Remote" -ErrorAction SilentlyContinue
    if ($okExe -and $s -and $s.Status -eq "Running") { $ok = $true; break }
  }
  if ($ok) { Set-Content -Path $mark -Value $best.tag -Encoding ASCII; L ("done " + $best.tag) }
  else { L ("install of " + $best.tag + " did not finish in 4 minutes") }
} catch {
  L ("error: " + $_.Exception.Message)
  exit 1
}
