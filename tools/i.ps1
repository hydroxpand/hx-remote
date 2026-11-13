# HX Remote one-line installer for Windows (ASCII only, no secrets in this file).
# Usage on a PC (PowerShell):
#   irm ("https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i.ps1").tolower() -outfile $env:temp\i.ps1; & "$pshome\powershell.exe" -ep bypass -f $env:temp\i.ps1 [password] [tag]
# Installs (or updates to) an HX Remote build as a service, optionally sets the unattended-access
# password, points the app at the company HX Remote server (ID and relay; the public RustDesk
# servers now ask the connecting side to sign in), registers the auto-update task, and prints the
# device ID. Running it again on an installed PC switches that PC to the company server too.
# The elevated window stays open until Enter. Without a tag it takes the newest complete hx-* release. Settings, ID and password
# survive an update. Updating from inside an HX Remote session drops that session for a minute.
# Auto-update: scheduled task "HX Remote Update" runs C:\Program Files\HX-Remote-Updater\hxupdate.ps1
# as SYSTEM (daily 03:30 and after startup). Pass -noupdater to skip it.
# -warp: also install Cloudflare WARP (only for PCs used outside the office: laptops, home PCs).
# WARP lets them reach the HX Remote server inside the company network without opening ports.
# The person signs in once with the company e-mail; no key is stored in this public script.
param([string]$pw = "", [string]$tag = "", [switch]$noupdater, [switch]$warp)
# Cloudflare Zero Trust team name (set when the company Zero Trust org is ready)
$WarpOrg = "purple-pond-45f0"
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"   # PS5 progress bar makes Invoke-WebRequest very slow
$me = $MyInvocation.MyCommand.Path
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  $ps = Join-Path $PSHOME "powershell.exe"   # full path: some PCs have WindowsPowerShell missing from PATH
  $a = "-ep bypass -f `"$me`" `"$pw`" `"$tag`""
  if ($noupdater) { $a += " -noupdater" }
  if ($warp) { $a += " -warp" }
  Start-Process $ps -Verb RunAs -ArgumentList $a
  exit
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = "hydroxpand/hx-remote"
$h = @{ "User-Agent" = "hx-remote-installer" }
function TagVer($t) {
  if ($t -match '^hx-(\d+)\.(\d+)\.(\d+)-(\d+)$') { return [version]("{0}.{1}.{2}.{3}" -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]) }
  return $null
}
Write-Host "== HX Remote setup on $env:COMPUTERNAME ==" -ForegroundColor Cyan
# pick the release: the given tag, or the newest one whose Windows exe is uploaded
$rels = @()
try { $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=20" -Headers $h -UseBasicParsing } catch { Write-Host ("GitHub API: " + $_.Exception.Message) -ForegroundColor Yellow }
$rel = $null; $relV = $null
foreach ($r in $rels) {
  $v = TagVer $r.tag_name
  if (-not $v -or $r.draft) { continue }
  if (-not ($r.assets | Where-Object { $_.name -like "*x86_64.exe" })) { continue }
  if ($tag) { if ($r.tag_name -eq $tag) { $rel = $r; break } else { continue } }
  if (-not $relV -or $v -gt $relV) { $rel = $r; $relV = $v }
}
if (-not $rel) {
  if (-not $tag) { Write-Host "No release found" -ForegroundColor Red; Read-Host "Enter to close"; exit 1 }
  Write-Host "Release $tag not found by the API, trying the direct link" -ForegroundColor Yellow
}
if ($rel) { $tag = $rel.tag_name }
Write-Host "build: $tag"
$url = "https://github.com/$repo/releases/download/$tag/rustdesk-1.5.1-x86_64.exe"
$app = "C:\Program Files\HX-Remote\HX-Remote.exe"
$mark = Join-Path $env:ProgramData "HX-Remote\build.txt"   # outside the install dir, survives reinstall
$cur = if (Test-Path $mark) { (Get-Content $mark -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "" }
$free = [int]((Get-PSDrive C).Free / 1MB)
Write-Host "C: free $free MB"
$need = -not ((Test-Path $app) -and ($cur -eq $tag))
if ($need) {
  if (Test-Path $app) { Write-Host ("updating " + $(if ($cur) { $cur } else { "old build" }) + " -> $tag") } else { Write-Host "new install $tag" }
  $old = if (Test-Path $app) { (Get-Item $app).LastWriteTimeUtc } else { $null }
  if ($free -lt 500) { Write-Host "Not enough space on C: (need 500 MB)" -ForegroundColor Red; Read-Host "Enter to close"; exit 1 }
  $f = Join-Path $env:TEMP "hx-remote-setup.exe"
  Write-Host "downloading ..."
  Invoke-WebRequest -Uri $url -OutFile $f -UseBasicParsing
  # check the download against SHA256SUMS when the release has one
  $sums = if ($rel) { $rel.assets | Where-Object { $_.name -eq "SHA256SUMS" } | Select-Object -First 1 } else { $null }
  if ($sums) {
    $sf = Join-Path $env:TEMP "hx-remote-SHA256SUMS"
    Invoke-WebRequest -Uri $sums.browser_download_url -OutFile $sf -UseBasicParsing -Headers $h
    $line = Get-Content $sf | Where-Object { $_ -match '\s\*?rustdesk-1\.5\.1-x86_64\.exe\s*$' } | Select-Object -First 1
    $want = if ($line) { (($line.Trim()) -split '\s+')[0].ToLower() } else { "" }
    $got = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
    if ($want -and $got -ne $want) { Write-Host "CHECKSUM MISMATCH, not installing" -ForegroundColor Red; Read-Host "Enter to close"; exit 1 }
    Write-Host "checksum ok"
  }
  Write-Host "installing ..."
  Start-Process -FilePath $f -ArgumentList "--silent-install"
  # done = new exe in place (newer than the old one on update) and the service is back
  for ($i = 0; $i -lt 48; $i++) {
    Start-Sleep -Seconds 5
    $okExe = (Test-Path $app) -and ((-not $old) -or ((Get-Item $app).LastWriteTimeUtc -ne $old))
    $s = Get-Service -Name "HX-Remote" -ErrorAction SilentlyContinue
    if ($okExe -and $s -and $s.Status -eq "Running") { break }
  }
  Start-Sleep -Seconds 5
  if (Test-Path $app) { New-Item -ItemType Directory -Force -Path (Split-Path $mark) | Out-Null; Set-Content -Path $mark -Value $tag -Encoding ASCII }
} else { Write-Host "already $tag" }
if (-not (Test-Path $app)) { Write-Host "INSTALL FAILED" -ForegroundColor Red; Read-Host "Enter to close"; exit 1 }
$svc = Get-Service -Name "HX-Remote" -ErrorAction SilentlyContinue
Write-Host ("service: " + $(if ($svc) { $svc.Status } else { "none" }))
# company HX Remote server (hbbs/hbbr); the key is the server's public key, not a secret
$hxServer = "172.30.1.34"
$hxKey = "ABuiNiIojpQ534We4SQfM1sW4laAXW8fBEfR7U+IrEU="
$opts = [ordered]@{ "custom-rendezvous-server" = $hxServer; "relay-server" = $hxServer; "key" = $hxKey }
foreach ($k in $opts.Keys) { & $app --option $k $opts[$k] | Out-Null; Start-Sleep -Milliseconds 500 }
$of = Join-Path $env:TEMP "hxremote_opt.txt"
cmd /c "`"$app`" --option custom-rendezvous-server > `"$of`" 2>&1"
$got = ((Get-Content $of -ErrorAction SilentlyContinue) -join " ").Trim()
if ($got -eq $hxServer) { Write-Host "server: $hxServer (company)" } else { Write-Host ("server setting not confirmed (got '" + $got + "')") -ForegroundColor Yellow }
if ($pw) { & $app --password $pw | Out-Null; Start-Sleep -Seconds 2; Write-Host "password set" }
# auto-update task (script from the hx branch; Program Files is not writable by normal users)
if (-not $noupdater) {
  try {
    $ud = "C:\Program Files\HX-Remote-Updater"
    New-Item -ItemType Directory -Force -Path $ud | Out-Null
    $us = Join-Path $ud "hxupdate.ps1"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/hx/tools/hxupdate.ps1" -OutFile $us -UseBasicParsing -Headers $h
    $ps = Join-Path $PSHOME "powershell.exe"
    $act = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$us`""
    $trg = @((New-ScheduledTaskTrigger -Daily -At "03:30"), (New-ScheduledTaskTrigger -AtStartup))
    $trg[1].Delay = "PT10M"
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $pr = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "HX Remote Update" -Description "HX Remote auto-update from github.com/hydroxpand/hx-remote (HydroXpand)" -Action $act -Trigger $trg -Settings $set -Principal $pr -Force | Out-Null
    # let signed-in users start the task (the "update now" button in the app); the script itself
    # lives in Program Files and cannot be changed by them
    try {
      $sch = New-Object -ComObject Schedule.Service; $sch.Connect()
      $tk = $sch.GetFolder("\").GetTask("HX Remote Update")
      $sd = $tk.GetSecurityDescriptor(4)
      if ($sd -notmatch "GRGX;;;AU") { $tk.SetSecurityDescriptor($sd + "(A;;GRGX;;;AU)", 0) }
    } catch { Write-Host ("task permission: " + $_.Exception.Message) -ForegroundColor Yellow }
    Write-Host "auto-update task: on (daily 03:30, log C:\ProgramData\HX-Remote\update.log)"
  } catch { Write-Host ("auto-update task failed: " + $_.Exception.Message) -ForegroundColor Yellow }
}
# Cloudflare WARP (optional): official installer, signature checked, organization preset
if ($warp) {
  try {
    $wcli = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
    if (-not $WarpOrg) {
      Write-Host "WARP: company setup not ready yet, skipped (run this installer again later)" -ForegroundColor Yellow
    } elseif (Test-Path $wcli) {
      Write-Host "WARP: already installed"
    } else {
      Write-Host "WARP: downloading Cloudflare WARP ..."
      $wf = Join-Path $env:TEMP "Cloudflare_WARP.msi"
      Invoke-WebRequest -Uri "https://downloads.cloudflareclient.com/v1/download/windows/ga" -OutFile $wf -UseBasicParsing -Headers $h
      $sig = Get-AuthenticodeSignature $wf
      if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notlike "*Cloudflare*") {
        Write-Host ("WARP: signature check failed (" + $sig.Status + "), not installing") -ForegroundColor Red
      } else {
        Write-Host "WARP: installing ..."
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList ("/i `"" + $wf + "`" /qn ORGANIZATION=`"" + $WarpOrg + "`"")
        if ($p.ExitCode -eq 0) { Write-Host "WARP: installed. Open Cloudflare WARP and sign in with your company e-mail once." -ForegroundColor Green }
        else { Write-Host ("WARP: installer exit code " + $p.ExitCode) -ForegroundColor Yellow }
      }
      Remove-Item $wf -Force -ErrorAction SilentlyContinue
    }
  } catch { Write-Host ("WARP: " + $_.Exception.Message) -ForegroundColor Yellow }
}
$idf = Join-Path $env:TEMP "hxremote_id.txt"
cmd /c "`"$app`" --get-id > `"$idf`" 2>&1"
$id = ((Get-Content $idf -ErrorAction SilentlyContinue) -join " ").Trim()
Set-Content -Path (Join-Path $env:PUBLIC "hxremote_id.txt") -Value "$env:COMPUTERNAME $id $tag" -Encoding ASCII
Write-Host ""
Write-Host "   HX REMOTE ID:  $id   ($env:COMPUTERNAME)" -ForegroundColor Green
Write-Host ""
Read-Host "Enter to close"
