# singbox_harmony · 鸿蒙原生 sing-box 客户端

一个 **HarmonyOS 原生**的 [sing-box](https://github.com/SagerNet/sing-box) 图形客户端：ArkTS / ArkUI 原生界面 + 系统 `VpnExtensionAbility` 管理 TUN + C++ N-API 桥接鸿蒙专版 sing-box 内核。

- 目标环境：华为 Mate XTs（GRL-AL20）/ HarmonyOS 7 / API 26，arm64
- 内核：sing-box **v1.14.3**（鸿蒙专版 arm64 动态库，源码构建）
- 界面：六个原生页面 + 桌面卡片，折叠 / 展开双布局适配
- 当前版本：**0.7.3**（自用调试签名版）
- 协议：应用包装层 GPL-3.0-or-later；内核归 SagerNet，见 [来源与许可](#来源与许可)

> 这是一个业余项目，由作者在一个周末内完成开发并通过真机验收，开发过程记录在作者的公众号文章里。它解决的是一个具体问题：**在鸿蒙上拥有一个功能完整、支持 IPv6 全接管的 own-network 客户端**——远程连回家庭 / 公司网络（WireGuard）、按规则分流自建节点的流量。

---

## 功能特性

按验证状态诚实分级：✅ 已在真机验证 ｜ 🟡 已实现、待真机验证 ｜ ❌ 未实现。

### 页面与配置管理 ✅

- **六个原生页面**：总览、配置、节点、连接、日志、设置；折叠 1008×2232 与展开 3184×2232 双布局，展开态 VPN 保持运行
- **多配置管理**：本地文件 / 剪贴板 / JSON 编辑 / 远程 URL 四种导入方式；校验、切换、更新、重命名、删除、导出
- **原子化存储**：配置采用私有锁 + 不可变版本文件 + 原子索引（0600 权限），下载期间编辑/删除/更新冲突时保留最新版本，不会用旧下载覆盖新配置
- **远程配置自动更新**：支持 1/6/12/24 小时及 7 天到期周期；前台检查与系统后台 WorkScheduler 共用更新锁、失败退避；结果不热替换当前隧道，手动重连后生效
- **标准导入链接**：支持 `sing-box://import-remote-profile?url=…#名称` 链接与远程配置链接二维码；链接先进草稿确认后再下载 🟡（原生扫码导入待真机验收）

### 节点与连接 ✅

- **selector 手动切换**：按配置内容隔离保存，重连后恢复
- **延迟测试**：整组 / 单节点测延迟，urltest 自动选择与测速结果展示
- **活动连接面板**：域名、地址、出站、匹配规则、流量统计、搜索、逐条/全部关闭连接（最新 200 条）
- **内核日志**：最近 100 条，支持搜索、清空、导出，URL 与常见凭据字段自动脱敏
- **实时速率与累计流量**，手动重连

### IPv6 与网络接管 ✅

- **双栈 TUN 全接管**：`172.19.0.1/30` + `fdfe:dcba:9876::1/126`，MTU 1280；显式申请 IPv4/IPv6 双栈默认路由（`0.0.0.0/0` + `::/0`）
- **蜂窝网络实测**：真机 `rmnet0` 上内核加载、双栈 TUN、默认路由建立/移除均验证；连续 5 次连接/断开通过
- **gVisor 双栈数据面**；TCP/UDP 53 端口进入内核 DNS
- **默认 DNS**：未指定时使用 AliDNS DoH（按物理接口 IPv6 能力选 `2400:3200::1` 或 `223.5.5.5`，TLS 校验名 `dns.alidns.com`）；指定则保留原设置
- **防回环双重保护**：`protectProcessNet()` + 每个出站 socket 经 `OH_NetConn_BindSocket` 绑定物理网络 ID
- **双栈自检**：一键检查 HTTP（v4/v6）与 DNS A/AAAA 解析，支持"直连诊断配置"做 TUN/内核基线验证与 IPv6 阻断负向测试

### WireGuard（连回家庭/公司网络）✅

- 外层 UDP 走与全局相同的物理网络保护绑定；启动时同步校验 UDP 创建结果
- 提供**握手时间、加密收发统计、家庭 DNS 应答检查**——不把"已启动"误报为"家庭网络可达"
- 仅允许用户态 WireGuard endpoint（`system:false`）

### 生命周期与自动化

- ✅ 打开 App 自动连接、网络丢失/切换后自动重试
- ✅ 指定 Wi-Fi SSID 暂停隧道、离开后恢复（默认不启用；SSID 功能仅在 VPN 服务运行时生效）
- ✅ 后台运行：普通后台任务、流量通知更新、定位辅助任务、后台订阅更新（WorkScheduler，周期≥2小时，系统择机执行不承诺准点）
- 🟡 **逐应用 VPN 范围**（所有 / 仅指定 / 排除指定）：已离线实现，待真机验证
- 🟡 桌面快捷入口（快速连接/断开）：待真机验收
- ❌ 系统 Always-On、系统级断网保护、开机自启

### 内核保留的配置能力 ✅

保留导入配置中的出站与路由规则（VLESS、WireGuard、selector、urltest、内联规则集均已在真机导入验证，并取得节点延迟结果）；应用统一替换入站，关闭配置中的远程控制面。指定证书设置时保留原值，未指定则使用 sing-box 内嵌 Mozilla 根证书库。

---

## 内核与架构

```
┌─────────────────────────────────────────────┐
│  ArkTS / ArkUI 层                            │
│  六页面 UI · VpnExtensionAbility 建 TUN 拿 fd │
│  配置管理 · 桌面卡片                          │
├─────────────────────────────────────────────┤
│  N-API 桥接层（C++）                          │
│  TunForwarder 读写 fd · SocketProtector 防回环│
│  PlatformBridge · OH_NetConn_BindSocket      │
├─────────────────────────────────────────────┤
│  sing-box 内核（Go，c-shared）                │
│  v1.14.3 · gVisor 数据面 · 路由/DNS/分流      │
└─────────────────────────────────────────────┘
```

- **内核**：sing-box [v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)，`core/go.mod` 固定依赖，arm64 鸿蒙动态库由本地源码构建（不使用预编译二进制）
- **Go 工具链**：Go 1.24.6+ 自举的鸿蒙 Go，使用第三方移植 [star4277/ohos-go v1.26.5-beta1](https://github.com/star4277/ohos-go/tree/19667c7abfc332f848b5bd1f293e4aeb0e9991a9)（固定 SHA `19667c7a…`，支持 `GOOS=openharmony` 与 arm64 TLSDESC）。不将普通 Linux/Android Go 库当作鸿蒙库使用
- **构建 tags**：`with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard`
- **已解决的坑**：Go 运行时与鸿蒙 musl 的 TLS 重定位冲突、VPN TUN fd 的 socket 元数据探测被沙箱拒绝（`scripts/prepare-ohos-module.py` 针对性处理）、鸿蒙 `fstat` 行为差异、DNS 初始化时序
- **质量检查**：Go race 测试、HAP 包内 arm64/TLSDESC/动态依赖检查、13 个 ETS 测试模块均通过（详见 `docs/build-verification-v0*.json`）

---

## 如何安装到手机

**重要**：HarmonyOS 不允许直接安装未签名的 HAP 包，本应用也未上架应用商店。当前唯一的安装方式是**自行构建，并用你自己的华为开发者账号生成调试签名**。整个过程在一台电脑上约 30–60 分钟（含工具链首次下载）。

### 你需要准备

1. 一台 Mac / Linux / Windows 电脑
2. [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 HarmonyOS SDK **API 26**）
3. 一个**华为开发者账号**（免费注册即可生成调试证书）
4. 一台 **HarmonyOS 7（API 26）** 的华为手机，打开开发者模式 + USB 调试
5. Go 1.24.6+（构建内核用）

### 安装步骤

```sh
# 1. 拉代码
git clone https://github.com/bigbearcool/singbox_harmony.git
cd singbox_harmony

# 2. 首次构建鸿蒙 Go 工具链（联网，一次性）
bash scripts/bootstrap-toolchain.sh

# 3. 编译内核 + 构建 HAP
cd core && go mod download && cd ..
bash scripts/build-core.sh
bash scripts/build-hap.sh

# 4. 签名（图形界面操作，见下方说明）
```

**签名（只需做一次）**：用 DevEco Studio 打开本工程 → **File → Project Structure → Signing Configs** → 勾选 **Automatically generate signature** → 登录你的华为开发者账号 → 为已连接的手机自动生成调试证书和 Profile。包名保持 `com.bigbear.singbox`，product `default` 引用生成的 signingConfig。保存后重新执行 `bash scripts/build-hap.sh`，确认输出 `entry-default-signed.hap`。

> 真实 `build-profile.json5` 是本机私有配置（已被 git 忽略），仓库只保存无签名的 `build-profile.example.json5`；构建脚本只在本机配置不存在时从模板复制，不会覆盖你已生成的签名。

**装进手机**：

```sh
bash scripts/device.sh install   # 安装（手机需已通过 USB 连接并授权调试）
bash scripts/device.sh launch    # 启动
```

**首次使用**：在配置页导入你的 sing-box 配置（文件 / 剪贴板 / JSON / 远程 URL 均可）→ 连接 → 第一次连接时系统会要求确认 VPN 授权 → 连接后点「检查连接」验证双栈 HTTP 与 DNS。

没有现成配置？先用配置页内置的「直连诊断」配置验证 TUN 与内核通路（该配置不提供任何远端出口，仅用于诊断）。

---

## 从源码构建（进阶）

- 本机默认 DevEco Studio 路径 `/Applications/DevEco-Studio.app`；可用 `OHOS_GO_FORK`、`DEVECO_SDK_HOME`、`OHOS_NATIVE_HOME` 覆盖构建环境
- `scripts/prepare-ohos-module.py` 在 `core/generated/` 创建固定版本依赖副本：传入已验证的 TUN 名、跳过沙箱拒绝的 socket 元数据探测、停用多余 Linux 接口绑定策略；脚本校验修改锚点，不改全局模块缓存
- 工具链位于 `.deps/`，不受 hvigor 根 `build/` 清理影响；依赖未缓存时首次构建需联网

### 验证

```sh
cd core
go test -race -modfile=generated/ohos.mod -tags with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard ./...
cd ..
node --test tests/profile_links.test.mjs tests/profile_store.test.mjs
python3 tests/verify_hap.py entry/build/default/outputs/default/entry-default-signed.hap
bash scripts/device.sh logs
```

真机验收记录：[docs/device-acceptance.md](docs/device-acceptance.md) · 各版本验证 JSON：`docs/build-verification-v0*.json` · SFM 功能对应与平台限制：[docs/sfm-feature-matrix.md](docs/sfm-feature-matrix.md) · 后台驻留方案：[docs/background-residency.md](docs/background-residency.md) · Wi-Fi 与桌面入口：[docs/wifi-and-quick-entry.md](docs/wifi-and-quick-entry.md)

调试构建支持负向自检：`bash scripts/device.sh launch-test reject-ipv6`（验证 IPv6 阻断），完成后 `launch-test direct` 恢复。测试启动参数只作用于空配置或内置诊断配置，不会替换真实用户配置。

---

## 已知限制（诚实版）

- MVP 未覆盖所有配置组合：使用域名作为代理服务器的配置应提供可用的 DNS 引导解析设置，避免 DNS 与出站循环依赖
- 后台长时间驻留（整夜、耗电）尚未完成验收，**不承诺永久常驻**
- Wi-Fi 环境实测暂缓，当前验收结论主要来自蜂窝网络
- 导入配置主动对 AAAA 返回空答案时，客户端保留原策略，自检会标明「已接管（配置返回空 AAAA）」
- 自检结果只证明测试目标（AliDNS、`one.one.one.one`）的路径可达，不等同于对所有目标可达

## 版本状态

- **0.7.3**（当前）：品牌化图标与卡片、青蓝/深蓝配色、安全区实时避让、折叠/展开双布局验收通过；双栈与 WireGuard 家庭 DNS 冷启动复测通过
- **0.6.1**：Wi-Fi SSID/网络类型接入内核规则；桌面卡片连接/断开/总览通过
- **0.5.6**：后台运行方案落地（通知更新、定位辅助、后台订阅）；逐应用范围离线实现
- **0.3**：蜂窝网络 WireGuard 实际握手、加密收发、家庭 DNS 成功应答
- **0.2**：内核加载、双栈 TUN、双栈默认路由基线

## 目录结构

```
core/                      Go 包装层与 sing-box 内核引用
entry/src/main/cpp/        N-API 桥（C++）
entry/src/main/ets/vpn/    系统 VPN 生命周期
entry/src/main/ets/pages/  原生页面
scripts/                   构建 / 工具链 / 设备部署脚本
tests/                     构建与数据配置检查
docs/                      验收记录与方案文档
```

## 来源与许可

sing-box 内核来自 [SagerNet/sing-box v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)，版权归其作者所有；本仓库的应用包装层（ArkTS 界面、N-API 桥、构建脚本）独立编写，按 **GPL-3.0-or-later** 提供。第三方组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 用途声明

本项目用于连接**你自己拥有和管理**的网络（家庭、公司自建服务），请遵守所在地区法律法规。工具是中性的，别拿它干不合适的事。
