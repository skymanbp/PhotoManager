@echo off
rem Test stand-in for a misbehaving tool: floods stdout (~24 KiB, well past the
rem 4 KiB anonymous-pipe buffer) WITHOUT ever reading stdin, then sleeps ~9 s.
rem Feeding a large stdin to it serially deadlocks (both sides blocked on a full
rem pipe); with the feed in its own thread, cancelling that thread first would
rem block until the child exits (the write is a non-interruptible FFI call).
rem Pm.Subprocess.runTool must kill the tree at the deadline, which frees the
rem write at once -- the 9 s sleep is long enough that "it exited by itself"
rem cannot masquerade as the kill (the test asserts elapsed < 4 s).
setlocal enabledelayedexpansion
set "line=0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
for /L %%i in (1,1,240) do echo !line!
ping -n 10 127.0.0.1 >nul
exit /b 0
