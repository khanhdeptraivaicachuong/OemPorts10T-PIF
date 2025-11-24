@echo off
REM Batch script to patch framework.jar
REM This script calls the PowerShell version for better functionality

setlocal

REM Check if framework.jar exists
if not exist "%~dp0framework.jar" (
    echo no framework.jar detected!
    exit /b 1
)

REM Run the PowerShell script
powershell.exe -ExecutionPolicy Bypass -File "%~dp0patchframework.ps1"

if errorlevel 1 (
    echo Script failed with error code %errorlevel%
    exit /b %errorlevel%
)

endlocal
