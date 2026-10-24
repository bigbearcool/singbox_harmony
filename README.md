# 熊盒 VPN · HarmonyOS 自用版

面向华为 Mate XTs（GRL-AL20）、HarmonyOS 7 / API 26 的原生 VPN MVP。
ArkTS / ArkUI 界面，系统 VpnExtensionAbility 管理 TUN，C++ N-API 桥接源码构建的 sing-box。

## 当前状态

- 已构建 sing-box 1.14.3 的 arm64 鸿蒙动态库与未签名 HAP。
- 配置测试、原生接口枚举测试通过；HAP 包内容、动态库依赖与 TLS 单独校验。
- 尚待生成本项目的调试签名并在真机安装。
- 尚未确认真机内核加载、VPN 路由生效及 IPv6 数据面通网。构建成功不代表这些检查通过。

## 第一版范围

- sing-box JSON 文件导入、粘贴配置、连接与断开。
- TUN：`172.19.0.1/30` 与 `fdfe:dcba:9876::1/126`，MTU 1280。
- 通过系统创建 TUN 后查询实际接口名，再向该接口申请 `0.0.0.0/0` 与 `::/0` 路由。
- 等待 `protectProcessNet()` 成功后才启动内核，防止代理出站回环。
- gVisor 双栈数据面；TCP/UDP 的 53 端口进入内核 DNS。
- 保留导入配置的出站与路由规则；由应用统一替换入站，关闭配置中的远程控制面。
- 未指定 DNS 时使用 DoH，并跟随配置的默认出站。指定 DNS 时保留原设置。
- 私有沙箱保存配置，文件权限 0600；签名配置、证书和构建产物不进入 Git。
- 网络切换后停止隧道并提示重新连接。第一版未实现无缝迁移、系统断网保护、订阅更新、独立节点选择界面或应用规则。

“使用直连诊断配置”仅用于验证 TUN 与内核，不提供远端代理出口。分流配置可以显式选择直连。
全接管的目标是普通应用的双栈数据流，仍需在目标系统上验证；内核所在进程须通过系统 API 豁免以建立出站连接。

## 构建

本机默认 DevEco Studio：`/Applications/DevEco-Studio.app`，SDK API 26。

```sh
bash scripts/bootstrap-toolchain.sh   # 首次构建工具链
cd core
go mod download
cd ..
bash scripts/build-core.sh
bash scripts/build-hap.sh
python3 tests/verify_hap.py entry/build/default/outputs/default/entry-default-unsigned.hap
```

初次构建使用 Go 1.24.6+ 自举鸿蒙 Go。工具链使用第三方移植
[star4277/ohos-go v1.26.5-beta1](https://github.com/star4277/ohos-go/tree/19667c7abfc332f848b5bd1f293e4aeb0e9991a9)，固定 SHA
`19667c7abfc332f848b5bd1f293e4aeb0e9991a9`，支持 `GOOS=openharmony` 和 arm64 TLSDESC。
未将普通 Linux/Android Go 库当作鸿蒙库使用。首次验证必须覆盖 ArkTS 工作线程与 VPN 扩展中的 Go 调用。

`core/go.mod` 与 `go.sum` 固定依赖；二进制由本地源码生成。工具链位于 `.deps/`，不会被 hvigor 的根 `build/` 清理影响。
使用 `OHOS_GO_FORK`、`DEVECO_SDK_HOME`、`OHOS_NATIVE_HOME` 可以覆盖构建环境。
依赖尚未缓存的机器首次构建需要联网。

## 签名与安装

1. DevEco Studio 打开当前工程，进入 **File → Project Structure → Signing Configs**。
2. 选 **Automatically generate signature**，本人登录华为开发者账号，为连接的手机生成调试证书和 Profile。
3. 包名必须为 `com.bigbear.singbox`；product `default` 必须引用生成的 signingConfig。
4. 保存后执行 `bash scripts/build-hap.sh`，确认输出 `entry-default-signed.hap`。
5. 执行 `bash scripts/device.sh install`，随后 `bash scripts/device.sh launch`。
6. 在手机中导入配置并连接，第一次连接需要本人确认系统 VPN 授权。

真实 `build-profile.json5` 是被忽略的本机配置；版本库保存无签名的 `build-profile.example.json5`。
构建脚本只在本机配置不存在时从模板复制，不覆盖已生成的签名。无需把密码发到聊天中。

## 验证

```sh
cd core
go test -race -tags with_gvisor,with_quic,with_utls,with_clash_api ./...
cd ..
python3 tests/verify_hap.py entry/build/default/outputs/default/entry-default-unsigned.hap
bash scripts/device.sh logs
```

真机验收清单见 [docs/device-acceptance.md](docs/device-acceptance.md)。
验收前不要把“内核运行”或“TUN 有 IPv6 地址”当成“IPv6 全接管已经通过”。

目录：`core/` 为 Go 包装层；`entry/src/main/cpp/` 为 N-API 桥；`entry/src/main/ets/vpn/` 为系统 VPN 生命周期；`tests/` 为构建与数据配置检查。

## 来源与许可

核心来自 [SagerNet/sing-box v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)。
应用包装层独立编写，按 GPL-3.0-or-later 提供。详见 LICENSE 与 THIRD_PARTY_NOTICES.md。
本工程尚未对外发布，也没有配置应用商店上传流程。
