@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Portable.ps1" %*
if errorlevel 1 echo Launch failed. Read the message above and runtime\logs.
pause
