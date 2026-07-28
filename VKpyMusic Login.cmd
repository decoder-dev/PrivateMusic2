@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if errorlevel 1 (
  echo Python launcher "py" was not found.
  echo Install Python 3.10 or newer and try again.
  pause
  exit /b 1
)

py -3.12 -c "import sys" >nul 2>nul
if errorlevel 1 (
  echo Python 3.12 was not found.
  echo Install Python 3.12 and try again.
  pause
  exit /b 1
)

if not exist ".vkpymusic-venv\Scripts\python.exe" (
  echo Creating an isolated VKpyMusic environment...
  py -3.12 -m venv ".vkpymusic-venv"
  if errorlevel 1 goto :failed
)

echo Installing the pinned VKpyMusic version...
".vkpymusic-venv\Scripts\python.exe" -m pip install --disable-pip-version-check "vkpymusic==4.0.2"
if errorlevel 1 goto :failed

".vkpymusic-venv\Scripts\python.exe" "scripts\vkpymusic_login.py"
set "helper_exit=%errorlevel%"
echo.
pause
exit /b %helper_exit%

:failed
echo.
echo VKpyMusic helper setup failed.
pause
exit /b 1
