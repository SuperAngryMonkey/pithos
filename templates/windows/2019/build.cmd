@echo off
REM Pithos Windows template build - runs once at first logon.
set LOG=C:\pithos-build.log
echo [%DATE% %TIME%] build start >> %LOG%

REM ---- 1. VirtIO guest tools (network, balloon, qemu-guest-agent) ----
set VIRTIO=
for %%d in (D E F G H) do if exist %%d:\virtio-win-guest-tools.exe set VIRTIO=%%d:
if "%VIRTIO%"=="" (echo ERROR: virtio CD not found >> %LOG%) else (
  echo installing guest tools from %VIRTIO% >> %LOG%
  "%VIRTIO%\virtio-win-guest-tools.exe" /install /passive /norestart >> %LOG% 2>&1
)

REM ---- 2. Tailscale ----
REM Installed but deliberately NOT authenticated: the auth key is per-clone and
REM is injected at first boot by Cloudbase-Init. Baking a key into a template
REM would let any copy of the image join the tailnet.
REM TS_UNATTENDEDMODE=always is essential - without it Tailscale only runs while
REM a user is interactively logged in, so a headless clone drops off the tailnet.
echo downloading Tailscale >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile 'C:\tailscale.msi'" >> %LOG% 2>&1

if exist C:\tailscale.msi (
  echo installing Tailscale - unattended mode, not authenticated >> %LOG%
  msiexec /i C:\tailscale.msi /quiet /norestart TS_UNATTENDEDMODE=always >> %LOG% 2>&1
) else (
  echo ERROR: Tailscale download failed - no network? >> %LOG%
)

REM ---- 3. Cloudbase-Init ----
REM The Windows cloud-init. Reads the Proxmox cloud-init drive on each clone's
REM first boot: sets hostname, password, and runs the tailscale up command that
REM Pithos writes into user-data.
echo downloading Cloudbase-Init >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing -Uri 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile 'C:\cbinit.msi'" >> %LOG% 2>&1

if exist C:\cbinit.msi (
  echo installing Cloudbase-Init >> %LOG%
  msiexec /i C:\cbinit.msi /qn /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1 >> %LOG% 2>&1
) else (
  echo ERROR: Cloudbase-Init download failed >> %LOG%
)

REM ---- 2b. Drop the Tailscale tray GUI ----
REM The GUI crashes at first logon (walk.NewNotifyIcon) because the shell is not
REM ready yet, and it is pointless here: the service runs unattended and does
REM all the work. Removing the shortcut stops the error on every clone.
del "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp\\Tailscale.lnk" >nul 2>&1

REM ---- 2b. Drop the Tailscale tray GUI ----
REM The GUI crashes at first logon (walk.NewNotifyIcon) because the shell is
REM not ready, and it is pointless here: the service runs unattended and does
REM all the work. Removing the shortcut stops the error on every clone.
del "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Tailscale.lnk" >nul 2>&1

REM ---- 3b. Point Cloudbase-Init at the Proxmox cloud-init drive ----
set CBDIR=%ProgramFiles%\Cloudbase Solutions\Cloudbase-Init\conf
if exist "%CBDIR%" (
  echo installing cloudbase-init.conf >> %LOG%
  copy /y "%~dp0cloudbase-init.conf" "%CBDIR%\cloudbase-init.conf" >> %LOG% 2>&1
  copy /y "%~dp0cloudbase-init.conf" "%CBDIR%\cloudbase-init-unattend.conf" >> %LOG% 2>&1
) else (
  echo ERROR: Cloudbase-Init conf dir not found >> %LOG%
)

REM ---- 4. Report ----
echo --- versions --- >> %LOG%
if exist "%ProgramFiles%\Tailscale\tailscale.exe" ("%ProgramFiles%\Tailscale\tailscale.exe" version >> %LOG% 2>&1) else (echo tailscale NOT installed >> %LOG%)
sc query Tailscale | findstr STATE >> %LOG% 2>&1
sc query cloudbase-init | findstr STATE >> %LOG% 2>&1
sc query QEMU-GA | findstr STATE >> %LOG% 2>&1

echo [%DATE% %TIME%] build done. Review %LOG%, then run sysprep.cmd from the config CD. >> %LOG%
