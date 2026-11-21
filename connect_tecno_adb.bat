@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Tecno ADB Connector

set "LASTFILE=%~dp0.tecno_adb_last.txt"

rem ---- locate adb.exe ----
set "ADB="
where adb >nul 2>&1 && for /f "delims=" %%P in ('where adb') do if not defined ADB set "ADB=%%P"
if not defined ADB if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not defined ADB if exist "%~dp0android\local.properties" (
  set "SDK="
  for /f "usebackq tokens=1,2 delims==" %%A in ("%~dp0android\local.properties") do if "%%A"=="sdk.dir" set "SDK=%%B"
  if defined SDK (
    set "SDK=!SDK:\:=:!"
    set "SDK=!SDK:\\=\!"
    if exist "!SDK!\platform-tools\adb.exe" set "ADB=!SDK!\platform-tools\adb.exe"
  )
)
if not defined ADB if defined ANDROID_HOME if exist "%ANDROID_HOME%\platform-tools\adb.exe" set "ADB=%ANDROID_HOME%\platform-tools\adb.exe"
if not defined ADB if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%\platform-tools\adb.exe" set "ADB=%ANDROID_SDK_ROOT%\platform-tools\adb.exe"
if not defined ADB if exist "C:\Android\platform-tools\adb.exe" set "ADB=C:\Android\platform-tools\adb.exe"
if not defined ADB if exist "C:\platform-tools\adb.exe" set "ADB=C:\platform-tools\adb.exe"
if not defined ADB (
  echo [X] adb.exe not found. Install Android SDK platform-tools or add adb to PATH.
  pause
  exit /b 1
)

:menu
cls
echo ============================================================
echo   TECNO ADB CONNECTOR
echo   adb: %ADB%
echo ============================================================
echo   Current devices:
"%ADB%" devices
echo.
echo   [P] Pair      first-time setup, uses the PAIRING code screen
echo   [C] Connect   press Enter to reuse the last address
echo   [D] Discover  auto-find wireless ADB via mDNS scan
echo   [T] USB-WiFi  one-time USB, then wireless on port 5555
echo   [U] USB fix   restart adb server + troubleshooting
echo   [Q] Quit
echo.
set "choice="
set /p "choice=Select: "
if /i "%choice%"=="P" goto pair
if /i "%choice%"=="C" goto connect
if /i "%choice%"=="D" goto discover
if /i "%choice%"=="T" goto tcpip
if /i "%choice%"=="U" goto usb
if /i "%choice%"=="Q" exit /b 0
goto menu

:pair
echo.
echo   ON THE PHONE: Settings - Developer options - Wireless debugging - ON
echo   tap "Pair device with pairing code" NOW and keep that screen open.
echo.
set "PAIRADDR="
set /p "PAIRADDR=Pairing IP:PORT as shown, e.g. 192.168.1.5:41234: "
set "CODE="
set /p "CODE=6-digit pairing code: "
if "%PAIRADDR%"=="" goto menu
echo.
"%ADB%" pair %PAIRADDR% %CODE%
echo.
echo   Notes:
echo   - Failed? The code AND the pairing port refresh every time you
echo     reopen the pairing screen. Reopen it and run [P] again.
echo   - "unknown command pair" = old platform-tools, update it.
echo   - Paired OK? Now use [C] with the MAIN address shown on the
echo     Wireless debugging screen - a DIFFERENT port than pairing.
pause
goto menu

:connect
set "DEF="
if exist "%LASTFILE%" set /p DEF=<"%LASTFILE%"
set "ADDR=%DEF%"
if defined DEF (
  set /p "ADDR=Connect IP:PORT [Enter = %DEF%]: "
) else (
  set /p "ADDR=Connect IP:PORT from the Wireless debugging screen: "
)
if "!ADDR!"=="" set "ADDR=%DEF%"
if "!ADDR!"=="" goto menu
echo.
set "RES="
for /f "delims=" %%R in ('"%ADB%" connect %ADDR% 2^>nul') do set "RES=%%R"
if defined RES echo   !RES!
echo !RES!| findstr /i "connected" >nul && echo %ADDR%>"%LASTFILE%"
"%ADB%" devices
echo   - "unauthorized": unlock the phone, tap Allow on the debugging prompt
echo   - refused/offline: the port changes whenever Wireless debugging toggles
pause
goto menu

:discover
echo.
echo   Scanning - phone must be on the same Wi-Fi as this PC...
"%ADB%" mdns check 2>nul
"%ADB%" mdns check 2>nul | findstr /i "unavailable" >nul && echo   [!] mDNS daemon unavailable - run [U] to restart adb, then retry [D].
echo.
set "FOUND="
set "PAIRING="
for /f "tokens=1,2" %%A in ('"%ADB%" mdns services 2^>nul') do (
  echo   service: %%A  at  %%B
  if "%%A"=="_adb-tls-connect._tcp." if not defined FOUND set "FOUND=%%B"
  if "%%A"=="_adb-tls-connect._tcp" if not defined FOUND set "FOUND=%%B"
  if "%%A"=="_adb-tls-pairing._tcp." if not defined PAIRING set "PAIRING=%%B"
  if "%%A"=="_adb-tls-pairing._tcp" if not defined PAIRING set "PAIRING=%%B"
)
echo.
if defined FOUND (
  echo   Found !FOUND! - connecting...
  for /f "delims=" %%R in ('"%ADB%" connect !FOUND! 2^>nul') do echo   %%R
  echo !FOUND!>"%LASTFILE%"
  "%ADB%" devices
  pause
  goto menu
)
if defined PAIRING (
  echo   A pairing service is waiting at !PAIRING!.
  echo   Open "Pair device with pairing code" on the phone, then run [P]
  echo   and enter that exact IP:PORT with the 6-digit code.
  pause
  goto menu
)
echo   Nothing found. Most common causes:
echo   - Windows Firewall blocks mDNS: run [U] once, allow adb on Private
echo     networks when the firewall prompt appears, then retry [D].
echo   - Phone and PC on different networks, or the router has AP isolation
echo     (phone-to-PC blocked). Using the phone's hotspot as a workaround.
echo   Fallback: run [C] and type the address shown on the phone.
pause
goto menu

:tcpip
echo.
echo   Plug the phone by USB (cable mode: File transfer/MTP), allow the
echo   debugging prompt, and keep it plugged for this step.
"%ADB%" devices
echo.
set "SER="
set /p "SER=Device id above (press Enter for the first device): "
set "SERDEF="
for /f "skip=1 tokens=1,2" %%D in ('"%ADB%" devices 2^>nul') do (
  if "%%E"=="device" if not defined SERDEF set "SERDEF=%%D"
)
if "%SER%"=="" set "SER=%SERDEF%"
if "%SER%"=="" (
  echo   No USB device detected. Run [U] for troubleshooting.
  pause
  goto menu
)
echo.
echo   Using device: %SER%
"%ADB%" -s %SER% tcpip 5555
echo.
echo   You can UNPLUG USB now. Detecting the phone's Wi-Fi IP...
set "PHONEIP="
for /f "tokens=9" %%I in ('"%ADB%" -s %SER% shell ip route 2^>nul') do (
  echo %%I| findstr /r "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" >nul && if not defined PHONEIP set "PHONEIP=%%I"
)
if not defined PHONEIP set "PHONEIP="
if not defined PHONEIP set /p "PHONEIP=Could not auto-detect. Type the phone's Wi-Fi IP: "
if not defined PHONEIP goto menu
"%ADB%" connect %PHONEIP%:5555
echo %PHONEIP%:5555>"%LASTFILE%"
"%ADB%" devices
echo   Note: this link lasts until the phone reboots or USB debugging
echo   toggles. No pairing needed for this method.
pause
goto menu

:usb
echo.
echo   Restarting the adb server...
"%ADB%" kill-server
"%ADB%" start-server
"%ADB%" devices
echo.
echo   If not listed at all:
echo     - cable mode must be File transfer/MTP, not Charging only
echo     - Developer options - USB debugging must be ON
echo     - Tecno HiOS extras: allow "USB debugging (Security settings)"
echo       and "Install via USB" too
echo     - try another cable/port (charge-only cables show nothing)
echo     - phone screen UNLOCKED; accept any popup that appears
echo   If listed "unauthorized": unlock the phone, tap Allow
echo   If listed "offline": rerun [U] with the USB replugged
pause
goto menu
