@echo off
title Terrastep Server - keep this window OPEN while testing
cd /d %~dp0

where python >nul 2>nul
if %errorlevel% neq 0 (
  echo Python was not found on this PC.
  echo Install Python 3 from https://www.python.org/downloads/ and tick
  echo "Add python.exe to PATH" during setup, then run this file again.
  pause
  exit /b 1
)

python -c "import h3" >nul 2>nul
if %errorlevel% neq 0 (
  echo Installing the one library the server needs ^(h3^)...
  python -m pip install h3==4.5.0
)

set TERRASTEP_HOST=0.0.0.0
set TERRASTEP_PORT=8791
set TERRASTEP_SECRET=terrastep-pilot-local-7f3a9c21

echo.
echo ============================================================
echo   TERRASTEP SERVER
echo   - Keep this window OPEN while you test the app.
echo   - Your phone must be on the SAME Wi-Fi as this PC.
echo   - If Windows Firewall asks, click ALLOW.
echo.
echo   This PC's address for the app ^(send this line to Muse^):
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4 Address"') do (
  set IP=%%a
  setlocal enabledelayedexpansion
  echo      http://!IP: =!:8791
  endlocal
)
echo ============================================================
echo.

python server\app.py
pause
