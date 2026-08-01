@echo off
REM One-tap launcher: auto-detects backend URL + connected Android device,
REM then runs the Flutter app. Equivalent to:
REM   powershell -ExecutionPolicy Bypass -File scripts\run_android.ps1

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\run_android.ps1"
endlocal
