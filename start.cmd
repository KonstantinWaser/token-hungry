@echo off
rem Puts token-hungry on the taskbar. Pass names to show only those: start.cmd Claude DeepSeek
rem conhost --headless gives PowerShell a console with no window; Windows Terminal ignores -WindowStyle Hidden.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0taskbar.ps1" %*
