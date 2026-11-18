@echo off
rem ============================================================
rem  Earth Dragon (Diniu) Wake Up to Telegram Earthquake Alert (Windows / PowerShell Version) (Windows launcher)
rem
rem  This file only forwards its arguments to earthdragon-wakeup_telegram.ps1.
rem  Keep it ASCII-only: cmd.exe parses this file before/after the
rem  code page change, and non-ASCII bytes in a .cmd can corrupt
rem  the parsing of the following lines on some systems.
rem
rem  Usage (Diniu Wake Up): point the interaction setting at this file.
rem  Usage (manual)       : earthdragon-wakeup_telegram.cmd --epicenter-lat=23.85 ...
rem
rem  Why %* and not %1..%9:
rem  Diniu Wake Up passes arguments unquoted, e.g. --depth=10, and
rem  cmd.exe treats '=' as an argument separator for %1..%9. %* keeps
rem  the original argument string intact. earthdragon-wakeup_telegram.ps1 accepts
rem  both "--name=value" and "--name value", so either form works.
rem ============================================================

setlocal EnableExtensions DisableDelayedExpansion

chcp 65001 >nul 2>&1

set "SCRIPT_DIR=%~dp0"

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%earthdragon-wakeup_telegram.ps1" %*

set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
