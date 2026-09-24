@echo off
rem Connect to Claude.cmd -- start Margince with a public address, for Claude.
rem
rem Double-click it INSTEAD of "Start Margince.cmd". All the work is in
rem runtime\connect-claude.ps1; this file exists because Explorer will run a .cmd
rem on a double-click and will not run a .ps1, and because -ExecutionPolicy
rem Bypass is what lets an unsigned script shipped inside a downloaded folder
rem run at all.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\connect-claude.ps1" %*
exit /b %ERRORLEVEL%
