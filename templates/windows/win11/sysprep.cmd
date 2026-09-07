@echo off
REM Pithos: seal the template. Run this LAST, from inside the VM.
REM Strips Store apps first - sysprep fails on provisioned/installed mismatches.

echo === Pithos template seal ===
echo.
echo Stripping Store apps (log: C:\pithos-appx.log)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strip-appx.ps1"
if errorlevel 1 echo WARNING: appx strip reported an error - check the log.

echo.
echo Clearing Windows Update cache...
net stop wuauserv >nul 2>&1
rd /s /q C:\Windows\SoftwareDistribution\Download >nul 2>&1
net start wuauserv >nul 2>&1

echo Clearing Tailscale node state...
REM If tailscale ever authenticated during the build, its state would be cloned
REM into every copy and they would fight over one node identity.
net stop Tailscale >nul 2>&1
rd /s /q "C:\ProgramData\Tailscale" >nul 2>&1

echo Disabling hibernation to reclaim disk...
powercfg /h off >nul 2>&1

echo.
echo Ready to generalize. This will shut the VM down.
echo After it stops: qm template ^<vmid^> on the Proxmox host.
pause

copy /y "%~dp0sysprep-unattend.xml" C:\sysprep-unattend.xml >nul 2>&1
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm /unattend:C:\sysprep-unattend.xml
