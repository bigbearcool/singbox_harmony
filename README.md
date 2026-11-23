# singbox_harmony · 熊盒 VPN（鸿蒙原生 sing-box 客户端）

一个 **HarmonyOS 原生**的 [sing-box](https://github.com/SagerNet/sing-box) 图形客户端：ArkTS / ArkUI 原生界面 + 系统 `VpnExtensionAbility` 管理 TUN + C++ N-API 桥接鸿蒙专版 sing-box 内核。

- 目标环境：华为 Mate XTs（GRL-AL20）/ HarmonyOS 7 / API 26，arm64
- 内核：sing-box **v1.14.3**（鸿蒙专版 arm64 动态库，源码构建，已编入 WireGuard / Tailscale / OpenVPN / OpenConnect / DHCP / QUIC / uTLS / gVisor）
- 界面：**4 栏 Surge 风格原生 UX**（总览 / 策略 / 活动 / 管理）+ `2×2` / `2×4` 实时状态桌面卡片，折叠 / 展开双布局适配
- 当前版本：**0.8.0**（自用调试签名版）
- 协议：应用包装层 GPL-3.0-or-later；内核归 SagerNet，见 [来源与许可](#来源与许可)

> 这是一个业余项目，由作者利用周末开发并通过真机验收，开发过程记录在作者的公众号文章里。它解决的是一个具体问题：**在鸿蒙上拥有一个功能完整、支持 IPv6 全接管、接近 Surge 使用体验的 own-network 客户端**——远程连回家庭 / 公司网络（WireGuard / Tailscale），并按规则分流自建节点的流量。

<div align="center">
  <img src="docs/assets/gzh-qrcode.jpg" alt="微信公众号「哎哟酷熊」二维码" width="180">
  <p><sub>扫码关注公众号「哎哟酷熊」，看这个项目和一个普通人是怎么用 AI 做出来的</sub></p>
</div>

---

## 功能特性

按验证状态诚实分级：✅ 已在真机验证 ｜ 🟡 已实现并完成离线测试、待真机补验 ｜ ❌ 平台限制 / 未实现。

### 4 栏 Surge 风格 UX 与桌面入口 ✅

- **总览（Dashboard）**：Hero 连接控制台、内置三态出站模式分段条（规则 / 全局 / 直连）、2×2 实时仪表盘（上下行速率与累计流量、Always-On 热切/自愈计数、活跃/最近请求快捷入口）、三联快捷工具（重连 / 体检 / 清缓存）、WireGuard 回家通道卡片与顶部悬浮自动消失 Toast
- **策略（Policy）**：可折叠策略组卡片 + **双列可点击节点网格**、延迟色标（`<150ms` 绿 / `<400ms` 黄 / `≥400ms` 珊瑚红）、一键整组/单节点测速、节点搜索与按延迟排序
- **活动（Activity）**：3 段式统一观测中心——`最近请求`（Go 环形缓冲最多 **500 条**含已结束短连接与耗时）/ `活跃连接`（最新 200 条，支持逐条或全部关闭）/ `内核日志`（最近 100 条，自动脱敏），顶部折叠「域名 / DNS 诊断」抽屉
- **管理（Manage）**：2 段式切换——`配置库`（顶部 4 格快捷导入：文件 / 剪贴板 / 扫码 / 链接与新建）与 `设置与覆写`（5 张分组卡片，低频项默认折叠）
- **实时状态桌面卡片**：支持 **`2×2` 与 `2×4`** 两种尺寸，事件驱动同步连接状态与网络类型（零后台轮询，不向桌面暴露配置/SSID/凭据），配合图标长按快捷方式一键连接 / 断开 / 打开总览
- **折叠屏双布局**：系统安全区实时避让，折叠 `1008×2232` 与展开 `3184×2232` 均已目视核对，展开态 VPN 持续运行

### Always-On 四层韧性底座（0.8.0）

- 🟡 **事件驱动 + TUN 保持热切换（Soft Handover）**：`connection.createNetConnection()` 监听网络变化并做 450ms 防抖，切网时优先通过内核 `update-physical-net` 原子更新底层物理 NetID 与 `ResetNetwork()`，**不拆 TUN、不撤回系统默认路由**；热切换失败才自动回退完整重建（离线单测通过，真实 Wi-Fi↔蜂窝切换待真机实测）
- 🟡 **切网黑洞防泄漏**：短暂断网或切网期间默认保留 TUN 最长 60 秒（可关闭），防止明文流量瞬间回退直连
- 🟡 **休眠唤醒与异常自愈**：单调时钟跳变检测（深度休眠唤醒自动 `reset-network`）、连续 `bindFailure` / `dnsError` 阈值自动降级恢复；持久化 `desired-state.json` 区分主动断开与系统回收
- ✅ **API 26 `VpnObserver` 授权监听**：精准感知系统 VPN 授权拒绝与取消
- ✅ **后台长时任务与定位辅助驻留**：支持数据传输后台任务与低功耗模糊定位辅助（15s 间隔，零坐标读取/保存/上传，实时显示任务 ID 与保活回调计数），已修复授权弹窗前台竞态并在真机确认 `MODE_LOCATION` 启动；整夜锁屏驻留与耗电仍待长期实测
- ❌ 系统级 Always-On 进程外自动拉起、系统级断网保护（Lockdown）、开机自启（受 HarmonyOS 7 公共权限边界限制）

### 图形化本地覆写与 SSID 策略联动（0.8.0）

- 🟡 **本地模块覆写（Local Overrides）**：独立保存于私有 `overrides.json`，不修改原始订阅，远程订阅自动更新后持久生效。提供 Surge 风格图形化构建器：点选类型（`DOMAIN` / `CIDR` / `Host 映射`）与彩色动作胶囊（`DIRECT` / `PROXY` / `REJECT`）一键添加，列表卡片一键删除，同时保留折叠的批量文本编辑
- 🟡 **SSID 策略联动**：在原有「指定 Wi-Fi 暂停隧道」基础上，新增 Surge 风格图形化构建器——按 Wi-Fi 名称自动切换出站模式（`mode`）、切换策略组节点（`group`）或暂停隧道（`pause`）；已连接时可直接点选当前配置的模式与策略组/节点，无需手写语法
- 🟡 **逐应用 VPN 范围**（所有 / 仅指定 / 排除指定，最多 256 个包名）：已离线实现，待真机引流实测

### 配置管理与自动更新 ✅

- **多配置原子化存储**：私有文件锁 + 不可变版本文件 + 原子索引（`0600` 权限），下载期间编辑/删除/更新冲突时保留最新版本
- **远程订阅自动更新**：支持 1/6/12/24 小时及 7 天到期周期；前台检查与系统后台 WorkScheduler（周期 ≥ 2 小时，系统择机执行）共用更新锁与指数退避；更新通过内核校验才替换，手动重连后生效
- **标准导入链接**：支持 `sing-box://import-remote-profile?url=…#名称` 链接与远程链接二维码（URI 分发与下载已真机通过；原生扫码导入 🟡 待真机验收）

### IPv6 双栈接管与 WireGuard 回家通道 ✅

- **双栈 TUN 全接管**：`172.19.0.1/30` + `fdfe:dcba:9876::1/126`，MTU 1280；显式申请 `0.0.0.0/0` + `::/0` 默认路由；gVisor 双栈数据面，TCP/UDP 53 端口进入内核 DNS
- **防回环双重保护**：`protectProcessNet()` + 每个出站 socket 经 `OH_NetConn_BindSocket` 绑定已确认的物理网络 ID
- **默认 DNS 与证书**：未指定 DNS 时使用 AliDNS DoH（按物理接口 IPv6 能力选 `2400:3200::1` 或 `223.5.5.5`，TLS 校验名 `dns.alidns.com`）；未指定证书时使用 sing-box 内嵌 Mozilla 根证书库；用户显式配置则原样保留
- **WireGuard 回家通道**：外层 UDP 走相同的物理网络保护绑定；提供握手时间、加密收发统计与家庭 DNS 实时检查，蜂窝网络下已真机验收

---

## 内核与架构

```
┌──────────────────────────────────────────────────────────┐
│  ArkTS / ArkUI 层                                        │
│  4 栏 Surge 风格 UI · 图形化规则/SSID 策略 · 2×2/2×4 卡片 │
│  VpnExtensionAbility（NetConnection 事件驱动 + 软切换）   │
├──────────────────────────────────────────────────────────┤
│  N-API 桥接层（C++）                                     │
│  libsingboxbridge.so · OH_NetConn_BindSocket 防回环      │
├──────────────────────────────────────────────────────────┤
│  sing-box 内核（Go，c-shared，arm64-v8a）                │
│  v1.14.3 · gVisor / QUIC / uTLS / WireGuard / Tailscale  │
│  OpenVPN / OpenConnect / DHCP / Clash API / 覆写与诊断   │
└──────────────────────────────────────────────────────────┘
```

- **内核**：sing-box [v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)，`core/go.mod` 固定依赖，arm64 鸿蒙动态库由本地源码构建（不使用预编译二进制）
- **Go 工具链**：Go 1.24.6+ 自举鸿蒙 Go，使用第三方移植 [star4277/ohos-go v1.26.5-beta1](https://github.com/star4277/ohos-go/tree/19667c7abfc332f848b5bd1f293e4aeb0e9991a9)（固定 SHA `19667c7a…`，支持 `GOOS=openharmony` 与 arm64 TLSDESC）
- **已开启构建 tags**（对齐 Mac 版 SFM 的全部纯 Go 模块）：
  - `with_gvisor`、`with_quic`、`with_utls`、`with_clash_api`、`with_wireguard`
  - `with_tailscale`（含 11 项 `ts_omit_*` 精简）、`with_openvpn`、`with_openconnect`、`with_dhcp`
  - 注：`with_naive_outbound` 依赖的 `cronet-go` 暂无 `openharmony/arm64` 原生库，未编入；`services` 与系统 TUN 型 endpoint 在校验层拦截
- **已解决的平台坑**：Go 运行时与鸿蒙 musl 的 TLS 重定位冲突、VPN TUN fd 的 socket 元数据探测被沙箱拒绝（`scripts/prepare-ohos-module.py` 针对性处理）、鸿蒙 `fstat` 行为差异、DNS 初始化时序
- **质量检查**：Go `-race` 全量测试、30 项 Node ETS 源码测试、HAP 包内 arm64/TLSDESC/strip 后核心一致性检查均通过

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

**首次使用**：进入 **管理 → 配置库** 导入你的 sing-box 配置（文件 / 剪贴板 / 扫码 / 远程 URL / JSON）→ 回到 **总览** 点击「连接 VPN」→ 首次连接确认系统 VPN 授权 → 连接后点击「体检」验证双栈 HTTP 与 DNS。

没有现成配置？先在 **管理 → 配置库 → 链接/新建** 中点「直连诊断预设」验证 TUN 与内核通路（该配置不提供任何远端出口，仅用于诊断）。

---

## 从源码构建与验证（进阶）

- 本机默认 DevEco Studio 路径 `/Applications/DevEco-Studio.app`；可用 `OHOS_GO_FORK`、`DEVECO_SDK_HOME`、`OHOS_NATIVE_HOME` 覆盖构建环境
- `scripts/prepare-ohos-module.py` 在 `core/generated/` 创建固定版本依赖副本：传入已验证的 TUN 名、跳过沙箱拒绝的 socket 元数据探测、停用多余 Linux 接口绑定策略；脚本校验修改锚点，不改全局模块缓存
- 工具链位于 `.deps/`，不受 hvigor 根 `build/` 清理影响；依赖未缓存时首次构建需联网

```sh
# Go 核心全量 race 测试
cd core
go test -race -modfile=generated/ohos.mod \
  -tags 'with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,with_openvpn,with_openconnect,with_dhcp' \
  ./...
cd ..

# 全部 30 项 ETS 源码单元测试
node --test tests/*.test.mjs

# HAP 包内 ABI / TLSDESC / 核心一致性校验
python3 tests/verify_hap.py entry/build/default/outputs/default/entry-default-signed.hap \
  --expected-core entry/src/main/cpp/prebuilt/arm64-v8a/libsingbox.so

# 查看真机运行日志
bash scripts/device.sh logs
```

验收与设计文档：[docs/device-acceptance.md](docs/device-acceptance.md) · `docs/build-verification-v0*.json` · [docs/sfm-feature-matrix.md](docs/sfm-feature-matrix.md) · [docs/background-residency.md](docs/background-residency.md) · [docs/wifi-and-quick-entry.md](docs/wifi-and-quick-entry.md)

调试构建支持负向自检：`bash scripts/device.sh launch-test reject-ipv6`（验证 IPv6 阻断），完成后 `launch-test direct` 恢复。测试启动参数只作用于空配置或内置诊断配置，不会替换真实用户配置。

---

## 已知限制（诚实版）

- 尚未覆盖所有配置组合：使用域名作为代理服务器的配置应提供可用的 DNS 引导解析设置，避免 DNS 与出站循环依赖
- 后台长时间驻留（拔线锁屏 30 分钟、整夜、耗电）尚未完成长期验收，**不承诺普通签名永久常驻**
- Wi-Fi 环境与真实 Wi-Fi↔蜂窝切换（Soft Handover / SSID 策略联动）尚待真机系统化验收，当前网络验收主要来自蜂窝网络
- 暂不支持真实 `wifi_bssid` 条件（公共 `GET_WIFI_INFO` 返回随机 BSSID）及 NaiveProxy（`cronet-go` 缺鸿蒙原生库）
- 导入配置主动对 AAAA 返回空答案时，客户端保留原策略，自检会标明「已接管（配置返回空 AAAA）」

## 版本演进

- **0.8.0**（当前）：Surge 对标全面升级——4 栏原生 UX + 图形化规则/SSID 策略构建器、Always-On 四层韧性底座（事件驱动 + TUN 保持热切换 + 黑洞保护 + 休眠自愈 + `VpnObserver`）、500 条最近请求与域名/DNS 诊断、本地模块覆写、全量纯 Go sing-box 模块（Tailscale/OpenVPN/OpenConnect/DHCP）、定位辅助驻留修复、`2×2`/`2×4` 实时状态桌面卡片
- **0.7.3**：品牌化机甲熊图标、青蓝/深蓝配色、安全区实时避让、折叠/展开双布局验收通过
- **0.6.1**：Wi-Fi SSID/网络类型接入内核规则；桌面卡片连接/断开/总览通过
- **0.5.6**：后台运行方案落地（通知更新、定位辅助、WorkScheduler 后台订阅）；逐应用范围离线实现
- **0.3**：蜂窝网络 WireGuard 实际握手、加密收发、家庭 DNS 成功应答
- **0.2**：内核加载、双栈 TUN、双栈默认路由基线

## 目录结构

```
core/                         Go 包装层（sing-box 内核、软切换、最近请求、诊断、本地覆写）
entry/src/main/cpp/           N-API 桥（C++）与预构建 arm64 libsingbox.so
entry/src/main/ets/vpn/       VpnExtensionAbility 生命周期与网络监听
entry/src/main/ets/common/    Always-On、本地覆写、后台保障、桌面卡片同步、配置库
entry/src/main/ets/pages/     4 栏 Surge 风格 ArkUI 页面
entry/src/main/ets/quickentry/ 2×2 & 2×4 实时状态桌面卡片
scripts/                      工具链自举 / 内核构建 / HAP 打包 / 真机部署脚本
tests/                        30 项 ETS 源码单测与 HAP 二进制校验
docs/                         验收记录、SFM 对照表与方案文档
```

## 来源与许可

sing-box 内核来自 [SagerNet/sing-box v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)，版权归其作者所有；本仓库的应用包装层（ArkTS 界面、N-API 桥、构建脚本）独立编写，按 **GPL-3.0-or-later** 提供。第三方组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 用途声明

本项目用于连接**你自己拥有和管理**的网络（家庭、公司自建服务），请遵守所在地区法律法规。工具是中性的，别拿它干不合适的事。

---

<div align="center">
  <img src="docs/assets/gzh-qrcode.jpg" alt="微信公众号「哎哟酷熊」二维码" width="180">
  <p><sub>觉得项目有用？扫码关注公众号「哎哟酷熊」——AI 落地、鸿蒙折腾、周末造轮子的真实记录</sub></p>
</div>
