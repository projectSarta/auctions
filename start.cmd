@echo off
REM Launch the local dashboard server. Double-click this file or run from a terminal.
REM The server listens on http://localhost:8123 and opens it in the default browser.
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0serve.ps1"
pause
