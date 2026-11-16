@echo off
rem Puts token-hungry on the taskbar. Pass names to show only those: start.cmd Claude DeepSeek
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0taskbar.ps1" %*
