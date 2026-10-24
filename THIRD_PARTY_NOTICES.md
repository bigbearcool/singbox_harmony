# Third-party source references

- **sing-box 1.14.3**, SagerNet: https://github.com/SagerNet/sing-box/tree/v1.14.3 — GPL-3.0-or-later. Core is built from Go module sources verified by `core/go.sum`; this project does not use a downloaded prebuilt core binary.
- **sing-box / sing-tun / gVisor platform adaptations** are applied by `scripts/prepare-ohos-module.py` to isolated copies of the exact versions pinned in `core/go.mod` and `core/go.sum`. Changes pass the verified HarmonyOS TUN name, bypass socket metadata probing only for the authorized TUN descriptor, and retain NetConn socket control instead of the Linux parallel interface strategy. Their upstream licenses remain applicable.
- **Mozilla root certificate store** is embedded by sing-box's certificate package and selected by default when the profile does not explicitly choose a certificate store. Its upstream certificate data and notices are retained in the pinned dependencies; TLS certificate verification is enabled.
- **OpenHarmony Go port**, star4277/ohos-go, tag v1.26.5-beta1, commit `19667c7abfc332f848b5bd1f293e4aeb0e9991a9`: https://github.com/star4277/ohos-go — Go BSD-style license and upstream notices. This is a third-party fork of the OpenHarmony-SIG Go port, not an official Huawei toolchain release.
- **OpenHarmony / HarmonyOS SDK**, supplied with locally installed DevEco Studio. SDK header and runtime terms apply, including the packaged C++ shared runtime.
- Transitive Go modules and versions are recorded in `core/go.mod`, `core/go.sum`, and the binary build information (`go version -m libsingbox.so`). Their upstream licenses remain applicable. No third-party notice is replaced by the app's license.

The bridge, application UI, VPN lifecycle and configuration policy in this repository are authored for this project. The upstream platform interfaces were consulted to implement compatible bindings. No full third-party HarmonyOS client was copied or rebranded.
