@echo off
title Codex server setup
echo ============================================
echo   Codex server - nastroyka / setup
echo ============================================
echo.
echo Zapusk nastroyki. Esli Windows sprosit razreshenie - nazhmite "Yes".
echo Esli sinee okno SmartScreen: "More info" / "Podrobnee" - "Run anyway".
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
echo.
echo ============================================
echo   Esli vyshe est OK_CONNECTED - vse gotovo!
echo ============================================
echo.
pause
