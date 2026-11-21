@echo off
setlocal
if not exist "%~dp0portable-manifest.json" goto missing_package
if not exist "%~dp0scripts\Stop-Portable.ps1" goto missing_package
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Stop-Portable.ps1" %*
set "stopResult=%errorlevel%"
if errorlevel 1 echo Stop failed. Read the message above.
pause
exit /b %stopResult%

:missing_package
echo This folder is GitHub source code or an incomplete portable package.
echo Download the full portable package from:
echo https://github.com/Wine-Tianci/FaFGame-Build/releases/latest
echo Choose faf-build-portable-*.zip and extract the complete folder.
pause
exit /b 1
