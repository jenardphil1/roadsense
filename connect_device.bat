@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Optional arg: connect_device.bat 192.168.100.15:PORT
rem Default below. Port changes whenever Wireless debugging is toggled on the phone.

set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" (
  set "SDK="
  for /f "usebackq tokens=1,2 delims==" %%A in ("%~dp0android\local.properties") do if "%%A"=="sdk.dir" set "SDK=%%B"
  if defined SDK (
    set "SDK=!SDK:\:=:!"
    set "SDK=!SDK:\\=\!"
    set "ADB=!SDK!\platform-tools\adb.exe"
  )
)

set "ADDR=%~1"
if "%ADDR%"=="" set "ADDR=192.168.100.15:4415"

echo Connecting to %ADDR% ...
set "RES="
for /f "delims=" %%R in ('"%ADB%" connect %ADDR% 2^>nul') do set "RES=%%R"
echo   !RES!
echo !RES!| findstr /i "connected" >nul
if errorlevel 1 (
  "%ADB%" devices 2>nul | findstr /c:"._adb-tls-connect._tcp" >nul && (
    echo   [OK] Device already connected wirelessly - the typed port is stale.
  ) || (
    echo   [X] Failed, no wireless device attached. Check: phone on same
    echo       Wi-Fi, Wireless debugging ON, IP:PORT matching the screen now.
  )
) else (
  echo !ADDR!>"%~dp0.tecno_adb_last.txt"
)
echo.
"%ADB%" devices
echo If it shows "unauthorized": unlock the phone and tap Allow.
