@echo off
rem Test stand-in for python (PM_PYTHON points here). `-c ...` (the `import PIL`
rem preflight) answers at once; everything else (the `-` derive call) sleeps ~3 s
rem and exits 0 WITHOUT writing the target. ConvertTests uses it to prove that
rem PM_CONVERT_TIMEOUT terminates the derive call inside the root lock and that
rem the pre-created .tmp is cleaned up afterwards.
if "%~1"=="-c" exit /b 0
ping -n 4 127.0.0.1 >nul
exit /b 0
