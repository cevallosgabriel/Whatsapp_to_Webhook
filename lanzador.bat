@echo off
chcp 65001 >nul
title Gestor de Ciclo de Vida - Evolution API ^& Gateway
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0motor.ps1" %*

if %errorlevel% neq 0 (
    echo.
    echo ==========================================================
    echo  El gestor finalizo con codigo de salida: %errorlevel%
    echo ==========================================================
    echo Presiona cualquier tecla para cerrar esta ventana...
    pause >nul
)
