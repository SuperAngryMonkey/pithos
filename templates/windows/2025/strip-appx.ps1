# Pithos: strip Store apps before sysprep.
#
# Sysprep fails with "was not able to validate your Windows installation" when a
# provisioned package and its per-user install disagree - which happens whenever
# Windows Update refreshes a Store app during the build. Removing both sides
# avoids it.
#
# Framework/runtime packages are KEPT: other software depends on them, and they
# do not cause sysprep failures.

$ErrorActionPreference = 'Continue'
$log = 'C:\pithos-appx.log'
function Log($m) { "$(Get-Date -f 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$keep = @(
  'Microsoft.VCLibs',
  'Microsoft.NET.Native.Framework',
  'Microsoft.NET.Native.Runtime',
  'Microsoft.UI.Xaml',
  'Microsoft.WindowsStore',            # keep the Store itself; removing it is hard to undo
  'Microsoft.DesktopAppInstaller',     # winget
  'Microsoft.SecHealthUI',             # Defender UI - removing breaks Security app
  'Microsoft.WindowsTerminal',
  'Microsoft.MicrosoftEdge'
)

function Keep($name) {
  foreach ($k in $keep) { if ($name -like "$k*") { return $true } }
  return $false
}

Log "=== appx strip start ==="

# 1. Per-user installs, for every user on the box. These are what most commonly
#    disagree with the provisioned list.
Log "--- removing installed packages (all users) ---"
Get-AppxPackage -AllUsers | ForEach-Object {
  if (Keep $_.Name) { Log "keep    $($_.Name)" ; return }
  try {
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
    Log "removed $($_.Name)"
  } catch {
    Log "FAILED  $($_.Name): $($_.Exception.Message)"
  }
}

# 2. Provisioned packages - the copies staged into the image for future users.
#    Leaving these behind means a fresh clone re-installs everything.
Log "--- removing provisioned packages ---"
Get-AppxProvisionedPackage -Online | ForEach-Object {
  if (Keep $_.DisplayName) { Log "keep    $($_.DisplayName)" ; return }
  try {
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
    Log "removed $($_.DisplayName)"
  } catch {
    Log "FAILED  $($_.DisplayName): $($_.Exception.Message)"
  }
}

# 3. Stop Store auto-updates. Without this, Windows re-downloads apps between
#    now and sysprep and the mismatch comes straight back.
Log "--- disabling Store auto-update ---"
$sp = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
if (-not (Test-Path $sp)) { New-Item -Path $sp -Force | Out-Null }
New-ItemProperty -Path $sp -Name AutoDownload -Value 2 -PropertyType DWord -Force | Out-Null

# Content Delivery Manager silently reinstalls "suggested" apps too.
$cd = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
if (-not (Test-Path $cd)) { New-Item -Path $cd -Force | Out-Null }
New-ItemProperty -Path $cd -Name DisableWindowsConsumerFeatures -Value 1 -PropertyType DWord -Force | Out-Null

# 4. Report what is left, so a sysprep failure can be diagnosed from the log.
Log "--- remaining provisioned ---"
Get-AppxProvisionedPackage -Online | ForEach-Object { Log "  $($_.DisplayName)" }

Log "=== appx strip done - safe to sysprep ==="
