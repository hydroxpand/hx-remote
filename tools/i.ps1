# HX Remote one-line installer for Windows (ASCII only, no secrets in this file).
# Usage on a PC (PowerShell):
#   irm https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i.ps1 -outfile $env:temp\i.ps1; & "$pshome\powershell" -ep bypass -f $env:temp\i.ps1 <password>
# Installs (or updates to) the HX Remote build $tag as a service (public RustDesk servers), optionally
# sets the unattended-access password, and prints the device ID. The elevated window stays open until Enter.
# Settings and the device ID survive an update. Updating from inside an HX Remote session drops that
# session for a minute; reconnect afterwards.
param([string]$pw = "", [string]$tag = "hx-1.5.1-8")
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"   # PS5 progress bar makes Invoke-WebRequest very slow
$me = $MyInvocation.MyCommand.Path
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  $ps = Join-Path $PSHOME "powershell.exe"   # full path: some PCs have WindowsPowerShell missing from PATH
  Start-Process $ps -Verb RunAs -ArgumentList "-ep bypass -f `"$me`" `"$pw`" `"$tag`""
  exit
}
$url = "https://github.com/hydroxpand/hx-remote/releases/download/$tag/rustdesk-1.5.1-x86_64.exe"
$app = "C:\Program Files\HX-Remote\HX-Remote.exe"
$mark = Join-Path $env:ProgramData "HX-Remote\build.txt"   # outside the install dir, survives reinstall
$cur = if (Test-Path $mark) { (Get-Content $mark -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "" }
Write-Host "== HX Remote setup on $env:COMPUTERNAME ==" -ForegroundColor Cyan
$free = [int]((Get-PSDrive C).Free / 1MB)
Write-Host "C: free $free MB"
$need = -not ((Test-Path $app) -and ($cur -eq $tag))
if ($need) {
  if (Test-Path $app) { Write-Host ("updating " + $(if ($cur) { $cur } else { "old build" }) + " -> $tag") } else { Write-Host "new install $tag" }
  $old = if (Test-Path $app) { (Get-Item $app).LastWriteTimeUtc } else { $null }
  if ($free -lt 500) { Write-Host "Not enough space on C: (need 500 MB)" -ForegroundColor Red; Read-Host "Enter to close"; exit 1 }
  $f = Join-Path $env:TEMP "hx-remote-setup.exe"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Write-Host "downloading ..."
  Invoke-WebRequest -Uri $url -OutFile $f -UseBasicParsing
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
if ($pw) { & $app --password $pw | Out-Null; Start-Sleep -Seconds 2; Write-Host "password set" }
$idf = Join-Path $env:TEMP "hxremote_id.txt"
cmd /c "`"$app`" --get-id > `"$idf`" 2>&1"
$id = ((Get-Content $idf -ErrorAction SilentlyContinue) -join " ").Trim()
Set-Content -Path (Join-Path $env:PUBLIC "hxremote_id.txt") -Value "$env:COMPUTERNAME $id $tag" -Encoding ASCII
Write-Host ""
Write-Host "   HX REMOTE ID:  $id   ($env:COMPUTERNAME)" -ForegroundColor Green
Write-Host ""
Read-Host "Enter to close"
