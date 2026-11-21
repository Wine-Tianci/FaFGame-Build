@echo off
setlocal
if not exist "%~dp0portable-manifest.json" goto missing_package
if not exist "%~dp0scripts\Start-Portable.ps1" goto missing_package
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Portable.ps1" %*
set "launchResult=%errorlevel%"
if errorlevel 1 echo Launch failed. Read the message above and runtime\logs.
pause
exit /b %launchResult%

:missing_package
echo This folder is GitHub source code or an incomplete portable package.
echo Download the full portable package from:
echo https://github.com/Wine-Tianci/FaFGame-Build/releases/latest
echo Choose faf-build-portable-*.zip and extract the complete folder.
echo Source code and update ZIPs are not a complete ready-to-use tool.
pause
exit /b 1
