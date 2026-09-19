@echo off
setlocal
title Sentinel Suite Setup
echo Setting up Sentinel Suite. This can take a while on the first run.
echo Keep this window open until setup finishes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Sentinel-Suite.ps1"
if errorlevel 1 (
    echo.
    echo Setup stopped. See the error above, then double-click this file again to retry.
    pause
    exit /b 1
)
exit /b 0
