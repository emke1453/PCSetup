@echo off
rem Startet das PC-Setup-Fenster mit Administrator-Rechten (Doppelklick genuegt)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
title PC-Setup
rem breite Konsole, damit winget lange Namen/IDs nicht abschneidet
mode con: cols=250 lines=30
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
