#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_DIR="${OHOS_GO_FORK:-$ROOT_DIR/.deps/ohos-go}"
GO_COMMIT=19667c7abfc332f848b5bd1f293e4aeb0e9991a9
mkdir -p "$(dirname "$GO_DIR")"
if [[ ! -d "$GO_DIR" ]]; then
 git clone --depth 1 --branch v1.26.5-beta1 https://github.com/star4277/ohos-go.git "$GO_DIR"
fi
[[ "$(git -C "$GO_DIR" rev-parse HEAD)" == "$GO_COMMIT" ]] || { echo 'Unexpected OHOS Go source revision' >&2; exit 1; }
export GOROOT_BOOTSTRAP="${GOROOT_BOOTSTRAP:-$(go env GOROOT)}"
export GOTOOLCHAIN=local
cd "$GO_DIR/src"
bash make.bash
"$GO_DIR/bin/go" tool dist list | rg '^openharmony/arm64$'
