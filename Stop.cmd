@echo off
rem ---------------------------------------------------------------------------
rem  notification-collector
rem  Double-click this file. No shell commands needed.
rem  (Japanese messages are printed by PowerShell, not by this batch file:
rem   the console code page here is not reliable, so keep this file ASCII.)
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

title notification-collector (stop)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1" -Stop
echo.
pause
