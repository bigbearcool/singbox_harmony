#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
case "${1:-status}" in
 status)
  "$HDC" list targets
  "$HDC" shell param get const.ohos.apiversion
  "$HDC" shell bm dump -n com.bigbear.singbox
  ;;
 install)
  HAP="$ROOT_DIR/entry/build/default/outputs/default/entry-default-signed.hap"
  [[ -f "$HAP" ]] || { echo 'A signed HAP is required. Configure Signing Configs in DevEco Studio, then rebuild.' >&2; exit 1; }
  "$HDC" install -r "$HAP"
  ;;
 launch)
  "$HDC" shell aa start -b com.bigbear.singbox -a EntryAbility
  ;;
 launch-test)
  PRESET="${2:-direct}"
  [[ "$PRESET" == direct || "$PRESET" == reject-ipv6 ]] || { echo 'Unknown diagnostic preset' >&2; exit 2; }
  "$HDC" shell aa force-stop com.bigbear.singbox
  "$HDC" shell aa start -b com.bigbear.singbox -a EntryAbility --ps diagnosticsProfile "$PRESET" --pb diagnosticsKeepAwake true
  ;;
 stop)
  "$HDC" shell aa force-stop com.bigbear.singbox
  ;;
 logs)
  "$HDC" shell hilog -x -T SingboxHarmony
  ;;
 *) echo 'usage: bash scripts/device.sh [status|install|launch|launch-test [direct|reject-ipv6]|stop|logs]' >&2; exit 2;;
esac
