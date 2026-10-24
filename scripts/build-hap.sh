#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO_DIR="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_DIR/sdk}"
export JAVA_HOME="$DEVECO_DIR/jbr/Contents/Home"
export PATH="$DEVECO_DIR/tools/node/bin:$DEVECO_DIR/tools/ohpm/bin:$PATH"
cd "$ROOT_DIR"
if [[ ! -f build-profile.json5 ]]; then cp build-profile.example.json5 build-profile.json5; fi
ohpm install
"$DEVECO_DIR/tools/hvigor/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
