@echo off
REM Double-click me on Windows: runs the FULL pipeline (all folds, seeds and epochs; ~2-4 h, resumable).
REM Smoke test instead:  run_pipeline.bat --profile quick
REM Picks a TensorFlow-compatible Python (3.12 > 3.11 > 3.13 > 3.10) via the py launcher.
cd /d "%~dp0"
set "ARGS=%*"
if "%~1"=="" set "ARGS=--profile full"
for %%V in (3.12 3.11 3.13 3.10) do (
    py -%%V -c "import sys" >nul 2>&1 && (
        py -%%V run_pipeline.py %ARGS%
        goto :end
    )
)
echo No Python 3.10-3.13 found via the py launcher. Install Python 3.12 from https://www.python.org/downloads/
echo (tick "Add python.exe to PATH" and keep the "py launcher" option), then double-click this file again.
:end
pause
