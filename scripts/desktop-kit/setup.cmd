@echo off
rem Setup.cmd -- prepare this installation before its first start.
rem
rem Double-click it. All the work is in runtime\setup.ps1; this file exists
rem because Explorer will run a .cmd on a double-click and will not run a .ps1,
rem and because -ExecutionPolicy Bypass is what lets an unsigned script shipped
rem inside a downloaded folder run at all.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\setup.ps1" %*
exit /b %ERRORLEVEL%
