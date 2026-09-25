#!/bin/bash
# Generate a cabal project for the Linux typecheck harness from the repo tree.
# The work dir (default: tools/linux-typecheck/work, git-ignored) gets a fresh copy of
# src/ app/ test/, a cbits stub (no windows.h), a hand-written photo-manager.cabal
# mirroring package.yaml, a cabal.project pointing at the Win32 stub package, and a
# freeze file derived from the Stackage LTS in stack.yaml (minus Win32).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${PM_HARNESS_DIR:-$HERE/work}"
mkdir -p "$WORK"; cd "$WORK"
rm -rf src app test cbits
cp -r "$REPO/src" "$REPO/app" "$REPO/test" .
mkdir -p cbits
cat > cbits/pm_win.c <<'CEOF'
/* Linux stand-ins for cbits/pm_win.c + the windows.h imports of Pm.Win. Never executed. */
#include <stdint.h>
typedef uint32_t DWORD; typedef void* HANDLE; typedef const uint16_t* LPCWSTR; typedef uint16_t* LPWSTR;
DWORD pm_get_file_attributes_err(LPCWSTR path, DWORD *err) { (void)path; *err = 0; return 0; }
DWORD pm_final_path_by_handle(HANDLE h, LPWSTR buf, DWORD cch, DWORD *err) { (void)h;(void)buf;(void)cch; *err=0; return 0; }
DWORD pm_open_for_dispose(LPCWSTR path, HANDLE *out, DWORD *err) { (void)path;(void)out; *err=0; return 0; }
DWORD pm_rename_by_handle(HANDLE h, LPCWSTR new_full, DWORD *err) { (void)h;(void)new_full; *err=0; return 0; }
DWORD pm_delete_by_handle(HANDLE h, DWORD *err) { (void)h; *err=0; return 0; }
DWORD pm_disable_backup_privileges(DWORD *err) { *err=0; return 1; }
DWORD SetErrorMode(DWORD m) { (void)m; return 0; }
DWORD GetDriveTypeW(LPCWSTR p) { (void)p; return 0; }
DWORD GetVolumeInformationW(LPCWSTR a, LPWSTR b, DWORD c, DWORD *d, DWORD *e, DWORD *f, LPWSTR g, DWORD h) { (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;(void)h; return 0; }
HANDLE FindFirstFileW(LPCWSTR p, void *d) { (void)p;(void)d; return (HANDLE)-1; }
int FindClose(HANDLE h) { (void)h; return 1; }
CEOF
LIBMODS=$(cd src && find . -name '*.hs' | sed 's|^\./||; s|\.hs$||; s|/|.|g' | sort | sed 's/^/                    /')
TESTMODS=$(cd test && find . -name '*.hs' ! -name Spec.hs | sed 's|^\./||; s|\.hs$||; s|/|.|g' | sort | sed 's/^/                    /')
VERSION=$(grep '^version:' "$REPO/package.yaml" | awk '{print $2}')
cat > photo-manager.cabal <<CEOF
cabal-version: 2.4
name:          photo-manager
version:       $VERSION
build-type:    Simple

common shared
  default-language: GHC2021
  ghc-options: -Wall -Wcompat -Widentities -Wincomplete-record-updates -Wincomplete-uni-patterns -Wredundant-constraints
  build-depends: base >= 4.20 && < 5, aeson, ansi-terminal, async, bytestring, containers, crypton, directory, filepath, optparse-applicative, text, time, toml-reader, Win32, http-types, memory, network, process, wai, warp

library
  import: shared
  hs-source-dirs: src
  c-sources: cbits/pm_win.c
  exposed-modules:
$LIBMODS

executable pm
  import: shared
  hs-source-dirs: app
  main-is: Main.hs
  ghc-options: -threaded -rtsopts -with-rtsopts=-N
  build-depends: photo-manager

test-suite pm-test
  import: shared
  type: exitcode-stdio-1.0
  hs-source-dirs: test
  main-is: Spec.hs
  ghc-options: -threaded
  c-sources: cbits/pm_win.c
  build-depends: photo-manager, process, tasty, tasty-hunit, tasty-quickcheck, temporary, http-types, wai, wai-extra
  other-modules:
$TESTMODS
CEOF
printf 'packages: . %s\n' "$HERE/win32-stub" > cabal.project
if [ ! -f cabal.project.freeze ]; then
  LTS=$(sed -n 's/^snapshot: *//p' "$REPO/stack.yaml")
  curl -sS -m 120 "https://www.stackage.org/$LTS/cabal.config" -o stackage.config
  grep -v '^\s*Win32 ' stackage.config | sed 's/^\s*constraints:/constraints:/' > cabal.project.freeze
fi
echo "generated in $WORK (freeze: $(sed -n 's/^snapshot: *//p' "$REPO/stack.yaml"))"
