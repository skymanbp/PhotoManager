@echo off
rem Test stand-in for the claude CLI (PM_CLAUDE_EXE points here; DESIGN-P8 s22.4).
rem The prompt arrives on stdin and is ignored. Mode comes from PM_FAKE_CLAUDE:
rem   (unset) -> a classify answer for a.jpg   place -> a fenced place answer
rem   garbage -> result is not JSON            fail  -> non-zero exit
rem   sleep   -> ~3 s delay (timeout test with PM_SUGGEST_TIMEOUT=1)
rem Output mimics `claude -p --output-format json`: one JSON object with "result".
if "%PM_FAKE_CLAUDE%"=="fail" exit /b 1
if "%PM_FAKE_CLAUDE%"=="garbage" (
  echo {"result":"sorry, I could not look at the images, no json here","is_error":false,"total_cost_usd":0.01}
  exit /b 0
)
if "%PM_FAKE_CLAUDE%"=="sleep" (
  ping -n 4 127.0.0.1 >nul
  echo {"result":"[]","is_error":false}
  exit /b 0
)
if "%PM_FAKE_CLAUDE%"=="place" (
  echo {"result":"Here you go:\n```json\n[{\"index\":1,\"place\":\"Atlanta\",\"basis\":\"downtown skyline\",\"confidence\":\"high\"},{\"index\":2,\"place\":null,\"basis\":\"indoor shots, nothing distinctive\",\"confidence\":\"low\"}]\n```","is_error":false,"total_cost_usd":0.02}
  exit /b 0
)
echo {"result":"[{\"name\":\"a.jpg\",\"category\":\"landscape\",\"location\":\"Hallstatt\",\"coordinates\":\"47.5, 13.6\",\"source\":\"ai-high\",\"basis\":\"lake and church tower\",\"title\":null},{\"name\":\"ghost.jpg\",\"category\":\"weird\",\"location\":null,\"coordinates\":\"999, 1\",\"source\":\"ai-high\",\"basis\":\"made up\",\"title\":null}]","is_error":false,"total_cost_usd":0.03}
exit /b 0
