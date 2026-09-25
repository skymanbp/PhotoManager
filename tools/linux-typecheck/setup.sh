#!/bin/bash
# One-time setup for the Linux typecheck harness: GHC 9.10.3 + cabal via ghcup, libgmp, cabal index.
# Safe to re-run. Nothing here touches the repository tree.
set -e
export PATH="$HOME/.ghcup/bin:$PATH"
if [ -f /root/.ccr/ca-bundle.crt ]; then
  export CURL_CA_BUNDLE=/root/.ccr/ca-bundle.crt SSL_CERT_FILE=/root/.ccr/ca-bundle.crt
fi
if ! command -v ghc >/dev/null 2>&1 || [ "$(ghc --numeric-version 2>/dev/null)" != "9.10.3" ]; then
  export BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=9.10.3 \
         BOOTSTRAP_HASKELL_CABAL_VERSION=latest BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 \
         BOOTSTRAP_HASKELL_ADJUST_BASHRC=0 GHCUP_USE_XDG_DIRS=0
  curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
fi
if ! ldconfig -p | grep -q libgmp.so; then
  (apt-get install -y libgmp-dev || (apt-get update && apt-get install -y libgmp-dev))
fi
ghc --version && cabal --version
cabal update
echo "setup done — next: tools/linux-typecheck/check.sh"
