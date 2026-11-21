@echo off
rem PROBELAUF der Automatik: zeigt, was Setup_auto.bat tun wuerde - es wird nichts veraendert.
rem   Setup_auto_probelauf.bat          -> zuletzt verwendetes Profil
rem   Setup_auto_probelauf.bat Gaming   -> Profil "Gaming"
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
title PC-Setup Automatik - PROBELAUF
mode con: cols=200 lines=50
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Auto -Probelauf -Profil "%~1"
echo.
echo Probelauf fertig. Fenster mit beliebiger Taste schliessen.
pause >nul
