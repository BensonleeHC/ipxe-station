@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Windows port of https://github.com/loglux/ipxe-station/blob/master/deploy.sh
rem Place beside docker-compose.yml in the repository root.
pushd "%~dp0" || exit /b 1
set "COMPOSE=docker compose"
docker compose version >nul 2>&1
if errorlevel 1 set "COMPOSE=docker-compose"
if "%DEV%"=="1" set "COMPOSE=%COMPOSE% -f docker-compose.yml -f docker-compose.dev.yml"
set "ACTION=%~1"
if not defined ACTION set "ACTION=help"
if /i "%ACTION%"=="--help" set "ACTION=help"
if /i "%ACTION%"=="-h" set "ACTION=help"
for %%C in (deploy redeploy frontend start stop restart logs status backup restore info help) do if /i "%ACTION%"=="%%C" goto dispatch
 echo [ERROR] Unknown command. Run deploy.bat help.
set "RC=1"
goto finish
:dispatch
call :cmd_%ACTION% "%~2"
set "RC=%ERRORLEVEL%"
:finish
popd
exit /b %RC%

:build_frontend
echo Building frontend...
if not exist "frontend\" (
    echo [WARN] No frontend directory; skipping.
    exit /b 0
)
where npm.cmd >nul 2>&1
if errorlevel 1 goto frontend_docker
pushd frontend || exit /b 1
call npm.cmd install
if errorlevel 1 (
    popd
    exit /b 1
)
call npm.cmd run build
set "BUILD_RC=%ERRORLEVEL%"
popd
if not "%BUILD_RC%"=="0" exit /b %BUILD_RC%
goto frontend_done
:frontend_docker
echo npm not found; building via Docker Node container...
docker run --rm -v "%CD%:/workspace" -w /workspace/frontend node:20-alpine sh -c "npm install && npm run build"
if errorlevel 1 exit /b 1
:frontend_done
echo Frontend built: app/frontend/dist/
exit /b 0

:wait_ready
echo Waiting for service on port 9021...
for /l %%I in (1,1,20) do (
    curl.exe -sf --max-time 5 http://localhost:9021/status >nul 2>&1
    if not errorlevel 1 (
        echo Service is up: http://localhost:9021
        exit /b 0
    )
    powershell.exe -NoProfile -Command "Start-Sleep -Seconds 2"
)
echo [WARN] Service did not respond in time. Check: %COMPOSE% logs -f
exit /b 0

:cmd_deploy
call :build_frontend
if errorlevel 1 exit /b 1
%COMPOSE% down --remove-orphans
if errorlevel 1 exit /b 1
%COMPOSE% up -d --build
if errorlevel 1 exit /b 1
call :wait_ready
exit /b %ERRORLEVEL%

:cmd_redeploy
call :build_frontend
if errorlevel 1 exit /b 1
%COMPOSE% down --remove-orphans --rmi local
if errorlevel 1 exit /b 1
%COMPOSE% up -d --build
if errorlevel 1 exit /b 1
call :wait_ready
exit /b %ERRORLEVEL%

:cmd_frontend
call :build_frontend
if errorlevel 1 exit /b 1
echo Hard-reload your browser with Ctrl+Shift+R.
exit /b 0

:cmd_start
%COMPOSE% up -d
exit /b %ERRORLEVEL%
:cmd_stop
%COMPOSE% down
exit /b %ERRORLEVEL%
:cmd_restart
%COMPOSE% restart
if errorlevel 1 exit /b 1
call :wait_ready
exit /b %ERRORLEVEL%
:cmd_logs
%COMPOSE% logs -f
exit /b %ERRORLEVEL%
:cmd_status
%COMPOSE% ps
if errorlevel 1 exit /b 1
rem PowerShell formats JSON without requiring a local Python installation.
powershell.exe -NoProfile -Command "$raw = docker exec ipxe-station curl -sf http://localhost:9021/status 2>$null; if ($LASTEXITCODE -eq 0) { try { $raw | ConvertFrom-Json | ConvertTo-Json -Depth 100 } catch { $raw } }"
exit /b 0

:cmd_backup
set "STAMP="
for /f %%T in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%T"
if not defined STAMP exit /b 1
set "ARCHIVE=ipxe-backup-%STAMP%.tar.gz"
if not exist "data\" (
    echo [ERROR] Data directory not found.
    exit /b 1
)
if exist "%ARCHIVE%" (
    echo [ERROR] Backup already exists: %ARCHIVE%
    exit /b 1
)
tar.exe -czf "%ARCHIVE%" data/
if errorlevel 1 exit /b 1
for %%F in ("%ARCHIVE%") do echo Backup saved: %%~fF [%%~zF bytes]
exit /b 0

:cmd_restore
set "ARCHIVE=%~1"
if not defined ARCHIVE (
    echo Usage: deploy.bat restore backup-file.tar.gz
    exit /b 1
)
if not exist "%ARCHIVE%" (
    echo [ERROR] Backup file not found.
    exit /b 1
)
choice /c YN /n /m "This will overwrite data/. Continue? [Y/N] "
if errorlevel 2 (
    echo Cancelled.
    exit /b 0
)
if errorlevel 1 exit /b 1
tar.exe -xzf "%ARCHIVE%"
if errorlevel 1 exit /b 1
echo Restore completed.
exit /b 0

:cmd_info
echo.
echo Container:
docker ps --filter name=ipxe-station --format "{{.Status}}"
echo URL: http://localhost:9021
echo Data directory: %CD%\data
echo.
powershell.exe -NoProfile -Command "'Storage:'; foreach ($n in 'tftp','http','ipxe','dhcp') { $p = Join-Path 'data/srv' $n; if (Test-Path -LiteralPath $p) { $s = (Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; '  {0,-24} {1:N2} MB' -f $p, ($s / 1MB) } }; ''; 'Ubuntu versions:'; $dirs = @(Get-ChildItem -LiteralPath 'data/srv/http' -Directory -Filter 'ubuntu-*' -ErrorAction SilentlyContinue | Sort-Object Name); if ($dirs.Count) { $dirs | ForEach-Object { '  ' + $_.Name } } else { '  none' }"
exit /b %ERRORLEVEL%

:cmd_help
echo.
echo iPXE Station - deploy.bat
 echo Usage: deploy.bat command [backup-file.tar.gz]
echo.
echo   deploy      Build frontend and Docker image, start container
 echo   redeploy    Rebuild frontend and image, remove local images, restart
 echo   frontend    Build frontend only; then press Ctrl+Shift+R in browser
 echo   start       Start containers
 echo   stop        Stop containers
 echo   restart     Restart containers and wait for readiness
 echo   logs        Follow container logs
 echo   status      Container status and service status JSON
 echo   backup      Archive data/ to a timestamped .tar.gz
 echo   restore     Restore a .tar.gz backup after confirmation
 echo   info        Show storage sizes and installed Ubuntu versions
 echo   help        Show this help
 echo.
echo Set DEV=1 to include docker-compose.dev.yml.
echo Requires Docker with Linux containers, Windows PowerShell, curl.exe,
echo and tar.exe. npm is optional; Docker Node is used when npm is absent.
exit /b 0
