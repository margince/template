@echo off
rem Load Demo Data.cmd -- fill this installation from the demo dataset.
rem
rem Double-click it. All the work is in runtime\load-demo-data.ps1; this file
rem exists because Explorer will run a .cmd on a double-click and will not run a
rem .ps1, and because -ExecutionPolicy Bypass is what lets an unsigned script
rem shipped inside a downloaded folder run at all.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\load-demo-data.ps1" %*
exit /b %ERRORLEVEL%
