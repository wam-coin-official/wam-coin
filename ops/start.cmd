@echo off
rem ===========================================================================
rem  Start the operations dashboard and open it.
rem
rem  Double-click this file. A console window stays open while the dashboard
rem  runs -- closing it stops the dashboard, which is the intended way to
rem  stop it. The page is reachable from this machine only.
rem ===========================================================================
title WAM operations dashboard
echo.
echo   Starting the WAM operations dashboard.
echo   It reads the servers over ssh and serves a page on this machine only.
echo   Close this window to stop it.
echo.
start "" http://127.0.0.1:9787
wsl -e bash -lc "cd /mnt/c/wam-blockchain-core && python3 ops/ops.py"
echo.
echo   The dashboard has stopped.
pause
