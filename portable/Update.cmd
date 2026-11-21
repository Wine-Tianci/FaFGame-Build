@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Portable.ps1" %*
if errorlevel 1 echo Update failed. Read the message above.
pause
