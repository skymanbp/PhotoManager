# Linux typecheck harness

pm is Windows-only (`Win32` FFI + `cbits/pm_win.c`), so it cannot be built or run in a Linux
container. This directory lets a Linux session still **compile** the whole library, the
executable and every test module under the project's `-Wall` flags, and run the pure-logic
subset of the test suite. It exists for AI/CI sessions that edit Haskell without a Windows box;
the authoritative build remains `stack test` on Windows (README "Build from source").

How it works:

- `win32-stub/` is a package named `Win32` (same version as Stackage lts-24.46) that exports
  only the symbols `Pm.Win` and the tests import, with `error`/no-op bodies. It exists so the
  code typechecks; anything that reaches a stub at runtime fails loudly.
- `gen-cabal.sh` copies `src/ app/ test/` into a git-ignored `work/` dir, writes a C stub for
  `cbits/pm_win.c` plus the `windows.h` symbols `Pm.Win` imports, generates a `.cabal`
  mirroring `package.yaml`, and freezes dependency versions to the LTS named in `stack.yaml`
  (minus `Win32`).
- `check.sh` re-syncs and builds lib + exe + tests. Exit code is cabal's.
- `run-tests.sh` runs the test binary from the repo root under a UTF-8 locale and compares the
  set of passing cases against `baseline-ok.txt` (132 pure cases as of 1.2.0). Cases that need
  Win32, `mklink`, ACLs, `\\.\NUL`, `tasklist` or `USERNAME` fail on Linux by construction.

Usage (first time takes ~15 min for GHC + dependencies):

```bash
tools/linux-typecheck/setup.sh      # ghcup → GHC 9.10.3 + cabal, libgmp-dev, cabal update
tools/linux-typecheck/check.sh      # build everything; prints only warnings/errors
tools/linux-typecheck/run-tests.sh  # Linux-passable tests vs baseline; -p '/pattern/' for one
```

Set `PM_HARNESS_DIR` to reuse an existing work dir elsewhere. Re-save the baseline with
`run-tests.sh --baseline` only after checking that the newly passing/failing cases are intended.
