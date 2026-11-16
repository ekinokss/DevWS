@echo off
setlocal EnableExtensions DisableDelayedExpansion
pwsh.exe -NoLogo -NoProfile -File "%LOCALAPPDATA%\DevWS\app\ws.ps1" %*
exit /b %ERRORLEVEL%
