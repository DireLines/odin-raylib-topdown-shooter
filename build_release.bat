:: This script creates an optimized release build.

@echo off

set OUT_DIR=build\release

if not exist %OUT_DIR% mkdir %OUT_DIR%

odin build source\main_release -out:%OUT_DIR%\game_release.exe -strict-style -no-bounds-check -o:speed -subsystem:windows
IF %ERRORLEVEL% NEQ 0 exit /b 1

echo Release build created in %OUT_DIR%