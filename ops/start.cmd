@echo off
rem ===========================================================================
rem  Start the operations dashboard and open it.
rem
rem  It now runs on WINDOWS Python, not inside WSL.
rem
rem  It used to run inside the WSL virtual machine and bind 127.0.0.1 there.
rem  On 2 September 2026 the Windows browser could not reach it -- not by
rem  localhost, not by the VM's own address -- and the process had also died
rem  at some point without anything to say so. The one tool whose whole job is
rem  to tell the founder when something is wrong was itself off, unreachable,
rem  and silent about both.
rem
rem  Served from Windows there is no VM between the browser and the page. The
rem  shell checks are still handed to WSL, which is where they were written to
rem  run; the ssh key, the ssh client and Python are all present on Windows
rem  already, so nothing else needed moving.
rem
rem  A console window stays open while it runs. Closing it stops the
rem  dashboard, which is the intended way to stop it.
rem ===========================================================================
title WAM operations dashboard
echo.
echo   Starting the WAM operations dashboard.
echo   It reads the servers over ssh and serves a page on this machine only.
echo   Close this window to stop it.
echo.

set "PY="
for %%P in (py.exe) do if not defined PY if exist "%%~$PATH:P" set "PY=py -3"
if not defined PY for %%P in (python.exe) do if not defined PY if exist "%%~$PATH:P" set "PY=python"
if not defined PY (
  echo   No Windows Python found. Install it, or run:
  echo     wsl -e bash -lc "cd /mnt/c/wam-blockchain-core ^&^& python3 ops/ops.py"
  pause
  exit /b 1
)

start "" http://127.0.0.1:9787
%PY% "%~dp0ops.py"
echo.
echo   The dashboard has stopped.
pause
