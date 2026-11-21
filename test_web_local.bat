@echo off
setlocal

echo ========================================================
echo  RoadSense Web - Local Development and Test Runner
echo ========================================================
echo.

cd /d "%~dp0"

REM Add flutter to PATH if not already present
set "PATH=%PATH%;C:\flutter\bin"

REM Configure port
set "PORT=8080"
if not "%~1"=="" set "PORT=%~1"

REM Detect browser
set "CHROME_EXECUTABLE="
set "DEVICE=edge"

if exist "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe" (
    set "CHROME_EXECUTABLE=%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe"
    set "DEVICE=chrome"
    echo [OK] Using Brave Browser: %LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe
    goto :START_RUN
)

if exist "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" (
    set "CHROME_EXECUTABLE=C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
    set "DEVICE=chrome"
    echo [OK] Using Brave Browser: C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe
    goto :START_RUN
)

if exist "C:\Program Files\Google\Chrome\Application\chrome.exe" (
    set "CHROME_EXECUTABLE=C:\Program Files\Google\Chrome\Application\chrome.exe"
    set "DEVICE=chrome"
    echo [OK] Using Google Chrome: C:\Program Files\Google\Chrome\Application\chrome.exe
    goto :START_RUN
)

if exist "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" (
    set "CHROME_EXECUTABLE=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    set "DEVICE=chrome"
    echo [OK] Using Google Chrome: C:\Program Files (x86)\Google\Chrome\Application\chrome.exe
    goto :START_RUN
)

echo [INFO] Brave/Chrome not found at default paths. Using Edge browser.

:START_RUN
echo Target Entrypoint: lib/web_main.dart
echo Web Port         : %PORT%
echo Device Target    : %DEVICE%
echo.
echo Controls while running:
echo   [r] Hot reload
echo   [R] Hot restart
echo   [q] Quit debug session
echo.
echo ========================================================
echo Starting Flutter Web...
echo ========================================================
echo.

call flutter run -d %DEVICE% -t lib/web_main.dart --web-port=%PORT% --web-hostname=localhost
if errorlevel 1 (
    echo.
    echo [WARN] Launch failed with %DEVICE%. Falling back to headless web-server...
    call flutter run -d web-server -t lib/web_main.dart --web-port=%PORT% --web-hostname=localhost
)

pause
