#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_DIR="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
NATIVE_DIR="${OHOS_NATIVE_HOME:-$SDK_DIR/default/openharmony/native}"
GO_DIR="${OHOS_GO_FORK:-$ROOT_DIR/.deps/ohos-go}"
GO_BIN="$GO_DIR/bin/go"
[[ -x "$GO_BIN" ]] || { echo "Missing OHOS Go toolchain. See README.md" >&2; exit 1; }
"$GO_BIN" tool dist list | rg -q '^openharmony/arm64$' || { echo "Toolchain must support openharmony/arm64" >&2; exit 1; }
export GOTOOLCHAIN=local GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1
export CC="$NATIVE_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang"
export CXX="$NATIVE_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang++"
export CGO_CFLAGS="-O2 -ftls-model=global-dynamic"
mkdir -p "$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a" "$ROOT_DIR/core/generated"
cat > "$ROOT_DIR/core/generated/exports.map" <<'MAP'
{ global: SBVersion; SBFree; SBCheck; SBStart; SBStop; SBStats; SBControl; local: *; };
MAP
cd "$ROOT_DIR/core"
python3 "$ROOT_DIR/scripts/prepare-ohos-module.py" "$GO_BIN"
"$GO_BIN" build -mod=readonly -modfile=generated/ohos.mod -trimpath -buildmode=c-shared \
 -tags 'with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard' \
 -ldflags "-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=1.14.3 -linkmode external -extldflags '-Wl,--version-script=$ROOT_DIR/core/generated/exports.map -Wl,-z,lazy -Wl,-soname,libsingbox.so'" \
 -o "$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a/libsingbox.so" .
"$NATIVE_DIR/llvm/bin/llvm-readelf" -h -l "$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a/libsingbox.so" > "$ROOT_DIR/core/generated/elf.txt"
"$NATIVE_DIR/llvm/bin/llvm-readelf" -r "$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a/libsingbox.so" > "$ROOT_DIR/core/generated/relocations.txt"
rg -q 'AArch64' "$ROOT_DIR/core/generated/elf.txt"
rg -q 'TLS' "$ROOT_DIR/core/generated/elf.txt"
rg -q 'R_AARCH64_TLSDESC' "$ROOT_DIR/core/generated/relocations.txt"
if rg -q 'R_AARCH64_TLS_TPREL' "$ROOT_DIR/core/generated/relocations.txt"; then echo 'Unsupported initial-exec TLS relocation' >&2; exit 1; fi
echo 'Core built; arm64 and TLSDESC verified.'
