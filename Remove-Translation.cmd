@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" -Action Remove
set "aac_exit=%ERRORLEVEL%"
echo.
pause
exit /b %aac_exit%
