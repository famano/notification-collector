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

title notification-collector

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1" %*
set "RC=%ERRORLEVEL%"

rem Keep the window open so a start-up error stays readable.
rem Closing on error is how "I double-clicked it and nothing happened" happens.
echo.
echo [exit code %RC%]
pause
