@echo off
rem Test stand-in for python (PM_PYTHON points here): sleeps ~3 s and exits 0.
rem Used by ConvertTests to prove PM_CONVERT_TIMEOUT kills the call (already at the
rem `import PIL` preflight) and leaves no .tmp behind.
ping -n 4 127.0.0.1 >nul
exit /b 0
