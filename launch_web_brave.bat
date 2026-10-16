@echo off
setlocal
echo ========================================================
echo  RoadSense Web - Launching in Brave Browser
echo ========================================================

set "CHROME_EXECUTABLE=C:\Users\jenar\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe"
if not exist "%CHROME_EXECUTABLE%" (
    echo [ERROR] Brave browser not found at: %CHROME_EXECUTABLE%
    pause
    exit /b 1
)

set "PATH=%PATH%;C:\flutter\bin"

echo Brave Executable: %CHROME_EXECUTABLE%
echo Starting Flutter Web debug session on port 8080...
echo.
echo Hot reload: Press 'r' in this window
echo Hot restart: Press 'R' in this window
echo Quit: Press 'q'
echo.

cd /d "%~dp0"
call flutter run -d chrome -t lib/web_main.dart --web-port=8080

pause
