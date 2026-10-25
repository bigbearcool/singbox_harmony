# 熊盒 VPN · HarmonyOS 自用版

面向华为 Mate XTs（GRL-AL20）、HarmonyOS 7 / API 26 的原生 VPN 客户端（0.2 自用签名版）。
ArkTS / ArkUI 界面，系统 VpnExtensionAbility 管理 TUN，C++ N-API 桥接源码构建的 sing-box。

## 当前状态

- 已构建 sing-box 1.14.3 的 arm64 鸿蒙动态库，生成调试签名 HAP，并安装到 Mate XTs。
- 真机蜂窝网络 `rmnet0` 上，内核加载、双栈 TUN、`0.0.0.0/0` 与 `::/0` 默认路由均已确认。
- 直连诊断基线中，绑定实际 VPN 网络的 IPv4/IPv6 HTTP 和 DNS A/AAAA 自检通过；加入 `::/0` 拒绝规则后 IPv6 HTTP 失败、IPv4 HTTP 仍成功。
- 连续 5 次连接/断开通过，每轮确认 IPv6 默认路由建立与移除。本机 Go race 测试、HAP 包内 arm64/TLSDESC/动态依赖检查通过。
- 已完整导入实际用户配置，保留 VLESS、WireGuard、selector、urltest 和内联规则集；真机已取得节点延迟结果。其他应用流量、WireGuard 家庭端握手、长时间锁屏及真实 Wi-Fi 切换仍需补充验收。

## 日常使用功能

- 六个原生页面：总览、配置、节点、连接、日志、设置。多配置的本地文件、剪贴板、JSON 编辑、远程 URL 导入，校验、切换、更新、重命名、删除和导出。
- 远程更新通过校验才替换旧配置；自动更新在 App 打开时每分钟检查，按每份配置的 24 小时间隔执行。系统结束 App 后不承诺定时后台执行。
- 正在运行的内核提供 selector 手动切换、整组/单节点延迟测试、urltest 当前选择和测速结果。手动选择按配置内容隔离，0600 原子保存，重连恢复。
- 活动连接的域名、地址、出站、匹配规则、流量、搜索、逐条/全部关闭；最多显示最新 200 条。最近 100 条内核日志支持搜索、清空、导出，URL 与常见凭据字段脱敏。
- 实时上下行速率与累计流量，手动重连，双栈 HTTP/DNS 自检，网络与 DNS 缓存重置。
- TUN：`172.19.0.1/30` 与 `fdfe:dcba:9876::1/126`，MTU 1280。
- 显式申请双栈默认路由；路由接口名与网关留空，由系统填入真实接口。通过实际双栈地址识别 TUN，并确认系统报告两条默认路由后才启动内核。
- 等待 `protectProcessNet()` 成功；内核每个出站 socket 还通过公共 `OH_NetConn_BindSocket` 绑定已确认的物理网络 ID，避免回环。
- gVisor 双栈数据面；TCP/UDP 的 53 端口进入内核 DNS。
- 保留导入配置的出站与路由规则；由应用统一替换入站，关闭配置中的远程控制面。
- 未指定 DNS 时使用 AliDNS DoH，根据物理接口 IPv6 地址选择 `2400:3200::1` 或 `223.5.5.5`，TLS 校验名为 `dns.alidns.com`；默认出站不是直连时配置 DNS detour。指定 DNS 时保留原设置。
- 未指定证书设置时使用 sing-box 内嵌 Mozilla 根证书库，保留 TLS 验证；指定证书设置时保留原值。
- 私有沙箱保存配置与控制请求，文件权限 0600；签名配置、证书和构建产物不进入 Git。
- 可设置打开 App 时自动连接、网络丢失/切换后自动重试，以及指定 Wi-Fi SSID 暂停隧道、离开后恢复。SSID 规则只在 VPN 服务仍运行时生效；系统杀进程后不会自行唤醒。默认不启用 SSID 暂停。
- 仅允许用户态 WireGuard endpoint（`system:false`，不指定监听端口），仍拒绝系统 TUN endpoint、其他 endpoint 类型和 services。
- 系统 Always-On、系统级断网保护、开机自启、桌面卡片和逐应用规则尚未实现；不能把普通自签应用等同于系统 VPN 管理权限。

“使用直连诊断配置”仅用于验证 TUN 与内核，不提供远端代理出口。分流配置可以显式选择直连。
双栈系统默认路由和内核接管路径已在目标设备实测。当前自检 socket 显式绑定 VPN，排除 VPN App 自身豁免带来的误判；其他应用和可控服务端出口地址仍需补充验收。
当前导入配置主动对 AAAA 返回空答案，客户端保留原策略；自检会标明“已接管（配置返回空 AAAA）”。IPv6 HTTP 与默认路由是独立验证项。
使用域名作为代理服务器的配置应提供可用的 DNS 引导解析设置，避免 DNS 与代理出站循环依赖；MVP 尚未覆盖所有配置组合。

## 构建

本机默认 DevEco Studio：`/Applications/DevEco-Studio.app`，SDK API 26。

```sh
bash scripts/bootstrap-toolchain.sh   # 首次构建工具链
cd core
go mod download
cd ..
bash scripts/build-core.sh
bash scripts/build-hap.sh
python3 tests/verify_hap.py entry/build/default/outputs/default/entry-default-signed.hap
```

初次构建使用 Go 1.24.6+ 自举鸿蒙 Go。工具链使用第三方移植
[star4277/ohos-go v1.26.5-beta1](https://github.com/star4277/ohos-go/tree/19667c7abfc332f848b5bd1f293e4aeb0e9991a9)，固定 SHA
`19667c7abfc332f848b5bd1f293e4aeb0e9991a9`，支持 `GOOS=openharmony` 和 arm64 TLSDESC。
未将普通 Linux/Android Go 库当作鸿蒙库使用。ArkTS 工作线程与 VPN 扩展中的 Go 调用已在真机验证。

`core/go.mod` 与 `go.sum` 固定依赖；二进制由本地源码生成。工具链位于 `.deps/`，不会被 hvigor 的根 `build/` 清理影响。
使用 `OHOS_GO_FORK`、`DEVECO_SDK_HOME`、`OHOS_NATIVE_HOME` 可以覆盖构建环境。
依赖尚未缓存的机器首次构建需要联网。

`scripts/prepare-ohos-module.py` 在忽略的 `core/generated/` 内创建固定版本依赖副本：传入已验证的 TUN 名，针对 VPN TUN fd 跳过沙箱拒绝的 socket 元数据探测，并停用额外的 Linux 接口绑定策略，保留公共 NetConn 绑定回调。脚本校验修改锚点，不改全局模块缓存。

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
go test -race -modfile=generated/ohos.mod -tags with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard ./...
cd ..
python3 tests/verify_hap.py entry/build/default/outputs/default/entry-default-signed.hap
bash scripts/device.sh logs
```

真机验收记录见 [docs/device-acceptance.md](docs/device-acceptance.md)，SFM 功能对应关系和平台限制见 [docs/sfm-feature-matrix.md](docs/sfm-feature-matrix.md)。
连接后点击“检查连接”，验证 HTTP、保留文档地址的 DNS 截获和实际虚拟 DNS 地址的 A/AAAA 查询。检查会访问 AliDNS 和查询 `one.one.one.one`，结果只证明这些测试目标的路径。

先在配置页添加并保存“直连诊断”配置，再复现负向检查。调试环境可使用 `bash scripts/device.sh launch-test reject-ipv6`，完成后断开并用 `launch-test direct` 恢复。这两个启动参数只在调试构建生效，只允许替换空配置或当前选中的内置诊断配置；真实用户配置不会被替换。测试启动会保持该窗口亮屏；正常 `launch` 不保持亮屏。停止 App 后正常启动即可恢复正常屏幕策略。

目录：`core/` 为 Go 包装层；`entry/src/main/cpp/` 为 N-API 桥；`entry/src/main/ets/vpn/` 为系统 VPN 生命周期；`tests/` 为构建与数据配置检查。

## 来源与许可

核心来自 [SagerNet/sing-box v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)。
应用包装层独立编写，按 GPL-3.0-or-later 提供。详见 LICENSE 与 THIRD_PARTY_NOTICES.md。
本工程尚未对外发布，也没有配置应用商店上传流程。
