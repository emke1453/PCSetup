@echo off
rem Installiert ein Profil vollautomatisch mit Konsolen-Log.
rem   Setup_auto.bat            -> zuletzt verwendetes Profil
rem   Setup_auto.bat Gaming     -> Profil "Gaming"
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '\"%~1\"' -Verb RunAs"
    )
    exit /b
)
cd /d "%~dp0"
title PC-Setup Automatik
mode con: cols=200 lines=50
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Auto -Profil "%~1"
echo.
echo Fertig. Fenster mit beliebiger Taste schliessen.
pause >nul
