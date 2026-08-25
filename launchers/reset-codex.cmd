@echo off
chcp 65001 >nul
set "reset_error_log=%TEMP%\reset-codex-%RANDOM%-%RANDOM%.stderr.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\Restore-GPT56Sol-ChatGPT.ps1" %* 2>"%reset_error_log%"
set "reset_exit_code=%ERRORLEVEL%"
if not "%reset_exit_code%"=="0" (
  if exist "%reset_error_log%" type "%reset_error_log%"
  if exist "%reset_error_log%" del /q "%reset_error_log%" >nul 2>&1
  echo Reset failed with exit code %reset_exit_code%.
  pause
  exit /b %reset_exit_code%
)
if exist "%reset_error_log%" del /q "%reset_error_log%" >nul 2>&1
echo Official GPT mode restored; local proxy routing is disabled.
timeout /t 3 /nobreak >nul
exit /b 0
