@echo off
chcp 65001 >nul
set "enable_error_log=%TEMP%\enable-cliproxy-%RANDOM%-%RANDOM%.stderr.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\Enable-CLIProxyAPI.ps1" %* 2>"%enable_error_log%"
set "enable_exit_code=%ERRORLEVEL%"
if not "%enable_exit_code%"=="0" (
  if exist "%enable_error_log%" type "%enable_error_log%"
  if exist "%enable_error_log%" del /q "%enable_error_log%" >nul 2>&1
  echo Enable failed with exit code %enable_exit_code%.
  pause
  exit /b %enable_exit_code%
)
if exist "%enable_error_log%" del /q "%enable_error_log%" >nul 2>&1
echo CLIProxyAPI routing enabled successfully. The selected mode is shown above.
timeout /t 3 /nobreak >nul
exit /b 0
