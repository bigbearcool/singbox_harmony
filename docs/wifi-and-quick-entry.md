# 0.6 Wi-Fi 条件与桌面入口

2026-10-25：0.6.1 已安装。蜂窝数据路径和实际桌面卡片操作通过；Wi-Fi 实测按用户要求暂缓。以下分别记录实现与验收范围。

## Wi-Fi 条件

- VPN 扩展从选定的底层物理网络读取类型；只有 Wi-Fi 网络才调用 `wifiManager.getLinkedInfo()`。启动通过 N-API 将网络类型和 SSID 传给 Go 平台接口，运行中相同接口的 SSID 变化通过内核私有调用同步，不经过持久化控制文件。
- `ReadWIFIState()` 返回当前名称，物理默认接口标注 Wi-Fi／蜂窝类型。导入配置的 `wifi_ssid`、`network_type` 条件可参与路由及 DNS 规则。规则仍遵循原 JSON，已有连接不因一次名称变化自动改路由。
- Wi-Fi 名称不可读、权限失败或系统返回未知占位符时，清除内核中的旧名称；切到蜂窝同样清除。空值及反向条件仍按 sing-box 配置自身语义处理，不宣称所有条件都不匹配。
- 设置中的“指定 Wi-Fi 暂停 VPN”优先暂停整个隧道；列表精确匹配、去重，最多 128 项，每个名称最多 32 UTF-8 字节，保留名称的大小写和空格。读取失败且物理 NetID 未变时保留原暂停状态；关闭该设置或读到不匹配名称后可恢复。明确断开不会被本功能自动重新连接。
- 当前公共 `GET_WIFI_INFO` 可能返回随机 BSSID，因此不向内核传入该值，也未新增受限 MAC 权限。真实 `wifi_bssid` 条件仍未对齐。
- 运行时 SSID 不写入状态文件、系统日志或桌面数据。原配置中的名称仍保存在私有配置内；导出日志时也对配置内 Wi-Fi 条件值脱敏。固定版本上游的 Wi-Fi／网络环境日志改为只记录变化事件。

## 桌面入口

- 图标快捷方式：连接 VPN、断开 VPN、VPN 总览。
- 2×2 服务卡片：连接、断开、打开总览。卡片只提供入口，不显示可能过期的 VPN 状态、配置名、节点或 Wi-Fi 信息，不创建轮询或定时刷新。
- 快捷操作先打开前台界面，再使用同一套系统 VPN API。首次连接仍需用户批准系统授权；首次使用没有配置时进入配置页。
- 冷启动与 `onNewWant` 均处理明确动作；导入 URI 不兼任连接指令。动作只有 connect/disconnect/overview，30 秒过期、仅前台消费、忙时延后、消费后清除。重复连接不会变为断开，重复断开不会变为连接。
- 启动方式为 singleton；显式快捷动作会抑制本次打开的自动连接，避免“断开”与原自动连接设置竞争。存在系统 VPN 但核心状态未知时保留检查入口，不把接口存在当作数据面通网证明。
- 卡片不承担 VPN 进程常驻、开机自启或系统强停后的唤醒。

## 离线证据

- Go race 全量核心测试通过；新增测试使用真实 daemon，确认首次 Wi-Fi 状态、默认接口类型、SSID 条件匹配、运行中改名和清除旧状态。未使用真实无线网络或 TUN。
- 12 个实际 ETS 源码测试模块通过；Wi-Fi 模块覆盖失败、精确匹配和暂停优先级，VPN 生命周期覆盖初始传递及实时同步，快捷模块覆盖实际 UIAbility 的冷／热启动与页面收件箱。SDK 替代对象不证明系统桌面行为。
- arm64 内核、桥接、ArkTS 与卡片编译及签名通过。包内核心经同样的 SDK strip 处理后与本次构建逐字节一致；快捷配置、卡片配置和 `widgets.abc` 已读回核对。
- 确切签名包、SHA-256 和签名校验结果见 `build-verification-v06.json`。旧 0.5.6 签名包独立保留。

## 真机验收清单

本轮已验证：原配置及设置保持不变，双栈 HTTP/DNS、WireGuard 家庭 DNS、冷启动及重复快捷 Want、系统卡片发现与添加、卡片连接／断开／总览和冷启动连接。真机发现默认 Button 内边距导致文字省略，0.6.1 改为无内边距的自定义文字按钮后，实际桌面显示清晰。图标长按菜单三项均可见，连接和断开点击通过；总览通过 Want 和卡片验证，菜单总览项实际点击未完成。最终保留一张可用卡片和已连接的原配置；普通冷启动恢复正常屏幕策略。

以下 Wi-Fi 场景暂缓；卡片移除／重新添加、菜单总览点击仍可后续补验。

1. 保留原配置安装候选；正常连接并重测双栈和 WireGuard 家庭 DNS。本版修改了启动 ABI，必须验证实际桥接加载。
2. 以无凭据的临时配置验证已知 Wi-Fi 的路由与 DNS 条件，分别切换同网 SSID、其他 Wi-Fi、蜂窝；核对实际数据路径，结束恢复原配置。
3. 验证暂停列表的进入／离开、关闭设置、暂时读不到名称及明确断开，观察旧路由释放与恢复。
4. 检查图标长按菜单，添加 2×2 卡片；分别验证冷启动、后台返回、重复点击、已断开再断开、无配置和首次系统授权，结束删除测试配置及调试亮屏。

## 接口依据

- 本机 API 26 `@ohos.wifiManager.d.ts`：`getLinkedInfo` 的 `GET_WIFI_INFO` 权限及无 MAC 权限时随机 BSSID 说明。
- 固定依赖 sing-box 1.14.3 的 libbox 平台接口、`CommandServer.UpdateWIFIState()`、网络管理器及 SSID／网络类型规则实现。
- [OpenHarmony：模块与快捷方式配置](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/quick-start/module-configuration-file.md#shortcuts标签)。
- [OpenHarmony：卡片配置](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/form/arkts-ui-widget-configuration.md)及[卡片 router 事件](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/form/arkts-ui-widget-event-router.md)。
