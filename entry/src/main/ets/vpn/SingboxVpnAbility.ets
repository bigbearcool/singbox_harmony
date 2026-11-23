import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import bridge from 'libsingboxbridge.so';
import { PhysicalNetworkState, SsidPolicyRule, SsidPolicyMatch, observeWifi, wifiPauseDecision, evaluateSsidPolicy } from '../common/WifiConditions';
import { loadSettings } from '../common/ProfileStore';
import { applyVpnScope, loadVpnScope } from '../common/VpnScope';
import { ControlRequest, ControlReply, ControlResult } from '../common/Control';
import { ClockJumpDetector, SelfHealTracker, SelfHealAction, HandoverDebouncer, DesiredVpnState, loadDesiredState, saveDesiredState, recordInterruption, recordHandover, recordSelfHeal } from '../common/AlwaysOn';
import { BUNDLE_NAME, VPN_ABILITY, readPrivate, writePrivate, initialStatus, VpnStatus, InterfaceAddress, CoreResponse, CoreStats } from '../common/Store';

export default class SingboxVpnAbility extends VpnExtensionAbility {
 private static readonly BLACKHOLE_MAX_MS: number = 60000;
 private static readonly RUNNING_MESSAGE: string = '内核运行中；IPv4 / IPv6 默认路由已确认';
 private conn?: vpnExtension.VpnConnection;
 private netConnection?: connection.NetConnection;
 private destroyed: boolean = false;
 private status: VpnStatus = initialStatus();
 private task: Promise<void> = Promise.resolve();
 private networkTimer: number = -1;
 private checkingNetwork: boolean = false;
 private physicalNetId: number = 0;
 private lastControlId: string = '';
 private lastSnapshotAt: number = 0;
 private bypassCurrentWifi: boolean = false;
 private pendingSsidPolicy?: SsidPolicyRule;
 private lastAppliedSsidPolicy: string = '';
 private networkState: PhysicalNetworkState = { type: 'other', ssid: '' };
 private lastSentNetwork: string = '';
 private lastStatusWrite: number = 0;
 private lastNetworkInspect: number = 0;
 private lastPhaseLog: string = '';
 private lastDnsLog: string = '';
 private lastBindFailures: number = 0;
 private blackholeSince: number = 0;
 private handoverCount: number = 0;
 private readonly handoverDebouncer: HandoverDebouncer = new HandoverDebouncer(450);
 private readonly clockJump: ClockJumpDetector = new ClockJumpDetector();
 private readonly selfHeal: SelfHealTracker = new SelfHealTracker();
 private udsServerFd: number = -1;
 private udsTimer: number = -1;
 private udsTimerMs: number = 0;
 private processingUds: boolean = false;

 private uiActive(): boolean {
  try {
   const demand: DashboardDemand = JSON.parse(readPrivate(`${this.context.filesDir}/ui-demand.json`)) as DashboardDemand;
   return Date.now() - demand.updatedAt < 8000 && demand.updatedAt <= Date.now() + 1000;
  } catch (_error) {
   return false;
  }
 }
 private inspectIntervalMs(): number {
  return this.uiActive() ? 1000 : 15000;
 }
 private isBlackholeEnabled(): boolean {
  const settings: Object = loadSettings(this.context.filesDir) as Object;
  const record: Record<string, Object | undefined> = settings as Record<string, Object | undefined>;
  return record['blackholeOnSwitch'] !== false;
 }
 private markDesiredConnected(): void {
  const current: DesiredVpnState = loadDesiredState(this.context.filesDir);
  const next: DesiredVpnState = {
   desired: 'connected',
   updatedAt: Date.now(),
   lastInterruptionAt: current.lastInterruptionAt,
   lastInterruptionReason: current.lastInterruptionReason,
   lastHandoverAt: current.lastHandoverAt,
   handoverCount: current.handoverCount || 0,
   selfHealCount: current.selfHealCount || 0
  };
  saveDesiredState(this.context.filesDir, next);
 }
 private registerNetConnection(): void {
  if (this.netConnection || this.destroyed) { return; }
  try {
   const netCon: connection.NetConnection = connection.createNetConnection();
   this.netConnection = netCon;
   netCon.on('netAvailable', (): void => { this.scheduleHandoverTick(); });
   netCon.on('netLost', (): void => { this.scheduleHandoverTick(); });
   netCon.on('netCapabilitiesChange', (): void => { this.scheduleHandoverTick(); });
   netCon.on('netConnectionPropertiesChange', (): void => { this.scheduleHandoverTick(); });
   netCon.register((_err: BusinessError): void => {});
  } catch (_error) {
   this.netConnection = undefined;
  }
 }
 private unregisterNetConnection(): void {
  this.handoverDebouncer.cancel();
  if (!this.netConnection) { return; }
  const netCon: connection.NetConnection = this.netConnection;
  this.netConnection = undefined;
  try {
   netCon.unregister((_err: BusinessError): void => {});
  } catch (_error) {}
 }
 private scheduleHandoverTick(): void {
  if (this.destroyed) { return; }
  this.handoverDebouncer.schedule((): void => {
   if (this.destroyed) { return; }
   this.lastNetworkInspect = 0;
   this.tick();
  });
 }

 onCreate(_want: Want): void {
  this.destroyed = false;
  this.markDesiredConnected();
  this.task = this.startVpn();
 }
 onDestroy(): void {
  this.destroyed = true;
  this.handoverDebouncer.cancel();
  if (this.networkTimer !== -1) { clearInterval(this.networkTimer); this.networkTimer = -1; }
  this.stopUdsServer();
  // Queue shutdown after any startup in flight, so a late start cannot resurrect the VPN.
  this.task = this.task.then(async () => {
   await this.cleanup();
   if (this.status.phase !== 'error') { this.publish('stopped', 'VPN 已停止'); }
  });
 }
 private publish(phase: string, message: string, force: boolean = false): void {
  const changed: boolean = this.status.phase !== phase || this.status.message !== message;
  this.status.phase = phase;
  this.status.message = message;
  if (!force && !changed && Date.now() - this.lastStatusWrite < (this.uiActive() ? 1000 : 5000)) { return; }
  this.status.updatedAt = Date.now();
  this.lastStatusWrite = this.status.updatedAt;
  writePrivate(`${this.context.filesDir}/vpn-status.json`, JSON.stringify(this.status));
  const signature: string = `${phase}|${this.status.tunName}|${this.status.physicalInterface}|${message}`;
  if (signature !== this.lastPhaseLog) {
   this.lastPhaseLog = signature;
   hilog.info(0x1700, 'SingboxHarmony', 'phase=%{public}s tun=%{public}s ipv6Address=%{public}s physical=%{public}s network=%{public}s physicalIPv6=%{public}s', phase, this.status.tunName, String(this.status.ipv6AddressPresent), this.status.physicalInterface, this.status.networkType || '', String(this.status.physicalIPv6Available || false));
  }
  if ((this.status.bindFailure || 0) !== this.lastBindFailures) {
   this.lastBindFailures = this.status.bindFailure || 0;
   hilog.warn(0x1700, 'SingboxHarmony', 'socketBind fail=%{public}d', this.lastBindFailures);
  }
  if ((this.status.dnsError || '') !== this.lastDnsLog) {
   this.lastDnsLog = this.status.dnsError || '';
   if (this.lastDnsLog) { hilog.warn(0x1700, 'SingboxHarmony', 'dnsStatus=%{public}s', this.lastDnsLog); }
  }
 }
 private requireAlive(): void { if (this.destroyed) { throw new Error('启动已取消'); } }
 private tick(): void {
  if (this.destroyed || this.checkingNetwork) { return; }
  // Track the complete in-flight tick so onDestroy waits for network probes,
  // core startup and reconnect cleanup before releasing the final resources.
  this.task = this.inspectNetwork();
 }
 private async physicalNetwork(): Promise<string> {
  const preferred: connection.NetHandle = await connection.getDefaultNet();
  const candidates: connection.NetHandle[] = [preferred, ...await connection.getAllNets()];
  for (const handle of candidates) {
   const caps: connection.NetCapabilities = await connection.getNetCapabilities(handle);
   if (caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) { continue; }
   if (!caps.networkCap?.includes(connection.NetCap.NET_CAPABILITY_INTERNET)) { continue; }
   const props: connection.ConnectionProperties = await connection.getConnectionProperties(handle);
   if (props.interfaceName.length > 0) {
    const settings = loadSettings(this.context.filesDir);
    const type: string = caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ? 'wifi' : caps.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR) ? 'cellular' : 'other';
    const observation = await observeWifi(type);
    const sameNetwork: boolean = this.physicalNetId === handle.netId;
    const policies: SsidPolicyRule[] = settings.ssidPolicies || [];
    const policyMatch: SsidPolicyMatch = policies.length > 0 ? evaluateSsidPolicy(policies, observation) : { matched: false };
    this.pendingSsidPolicy = policyMatch.matched ? policyMatch.rule : undefined;
    const pauseByList: boolean = wifiPauseDecision(settings.onDemand, settings.bypassWifi, observation, this.bypassCurrentWifi, sameNetwork);
    const pauseByPolicy: boolean = (policyMatch.matched && policyMatch.rule !== undefined && policyMatch.rule.action === 'pause') || (!observation.known && type === 'wifi' && sameNetwork && this.bypassCurrentWifi && policies.some((r: SsidPolicyRule): boolean => r.action === 'pause'));
    this.bypassCurrentWifi = pauseByList || pauseByPolicy;
    this.networkState = observation.state;
    this.status.wifiConditionStatus = type === 'wifi' ? (observation.known ? 'Wi-Fi 条件可用（SSID）' : 'Wi-Fi 名称暂不可读；已清除旧名称，同网暂停状态保持') : '当前使用非 Wi-Fi 网络';
    this.physicalNetId = handle.netId;
    this.status.networkType = caps.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR) ? '蜂窝网络' : caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ? 'Wi-Fi' : '其他网络';
    this.status.physicalIPv6Available = props.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.family === 2 && !it.address.address.startsWith('fe80:'));
    return props.interfaceName;
   }
  }
  throw new Error('没有可用的物理网络');
 }
 private makeConfig(): vpnExtension.VpnConfig {
  const config: vpnExtension.VpnConfig = {
   addresses: [{ address: { address: '172.19.0.1', family: 1 }, prefixLength: 30 }, { address: { address: 'fdfe:dcba:9876::1', family: 2 }, prefixLength: 126 }],
   // Empty interface requests system GetInterfaceName(). An empty gateway is
   // essential: the route service passes this string even if hasGateway=false.
   routes: [
    { interface: '', destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 }, gateway: { address: '', family: 1 }, hasGateway: false, isDefaultRoute: true },
    { interface: '', destination: { address: { address: '::', family: 2 }, prefixLength: 0 }, gateway: { address: '', family: 2 }, hasGateway: false, isDefaultRoute: true }
   ],
   dnsAddresses: ['172.19.0.2', 'fdfe:dcba:9876::2'],
   mtu: 1280,
   isIPv4Accepted: true,
   isIPv6Accepted: true,
   isBlocking: false
  };
  return applyVpnScope(config, loadVpnScope(this.context.filesDir));
 }
 private async confirmRoutes(): Promise<void> {
  for (let attempt: number = 0; attempt < 20; attempt++) {
   for (const net of await connection.getAllNets()) {
    const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
    if (!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) { continue; }
    const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
    if (props.interfaceName !== this.status.tunName) { continue; }
    const ipv4: boolean = props.routes.some((r: connection.RouteInfo): boolean => r.destination.address.address === '0.0.0.0' && r.destination.prefixLength === 0);
    const ipv6: boolean = props.routes.some((r: connection.RouteInfo): boolean => r.destination.address.address === '::' && r.destination.prefixLength === 0);
    if (ipv4 && ipv6) { return; }
   }
   this.requireAlive();
   await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
  }
  throw new Error('系统尚未建立 IPv4/IPv6 两条默认路由，已中止连接');
 }
 private async applySsidPolicy(): Promise<void> {
  const rule: SsidPolicyRule | undefined = this.pendingSsidPolicy;
  if (!rule || rule.action === 'pause') {
   this.lastAppliedSsidPolicy = '';
   return;
  }
  if (rule.action === 'mode' && rule.mode && rule.mode.length > 0) {
   const key: string = `${rule.ssid}|mode|${rule.mode}`;
   if (key === this.lastAppliedSsidPolicy) { return; }
   const req: ModeControlRequest = { action: 'mode', mode: rule.mode };
   try {
    const reply: CoreResponse = JSON.parse(await bridge.control(JSON.stringify(req))) as CoreResponse;
    if (reply.ok) { this.lastAppliedSsidPolicy = key; }
   } catch (_error) {}
  } else if (rule.action === 'group' && rule.group && rule.group.length > 0 && rule.outbound && rule.outbound.length > 0) {
   const key: string = `${rule.ssid}|group|${rule.group}|${rule.outbound}`;
   if (key === this.lastAppliedSsidPolicy) { return; }
   const req: SelectControlRequest = { action: 'select', group: rule.group, outbound: rule.outbound };
   try {
    const reply: CoreResponse = JSON.parse(await bridge.control(JSON.stringify(req))) as CoreResponse;
    if (reply.ok) { this.lastAppliedSsidPolicy = key; }
   } catch (_error) {}
  }
 }
 private async trySoftHandover(name: string): Promise<boolean> {
  try {
   const req: UpdatePhysicalNetRequest = {
    action: 'update-physical-net',
    interfaceName: name,
    netId: this.physicalNetId,
    network: this.networkState
   };
   const reply: CoreResponse = JSON.parse(await bridge.control(JSON.stringify(req))) as CoreResponse;
   if (this.destroyed) { return true; }
   if (!reply.ok) { return false; }
   this.status.physicalInterface = name;
   this.lastSentNetwork = JSON.stringify(this.networkState);
   this.blackholeSince = 0;
   this.handoverCount = recordHandover(this.context.filesDir);
   this.publish('running', SingboxVpnAbility.RUNNING_MESSAGE);
   return true;
  } catch (_error) {
   return false;
  }
 }
 private async startVpn(): Promise<void> {
  let retryable: boolean = false;
  let startupHint: string = '';
  if (this.networkTimer !== -1) { clearInterval(this.networkTimer); this.networkTimer = -1; }
  try {
   this.blackholeSince = 0;
   this.status.uplink = 0; this.status.downlink = 0; this.status.bindSuccess = 0; this.status.bindFailure = 0; this.status.dnsError = '';
   this.publish('starting', '检查配置与物理网络');
   const config: string = readPrivate(`${this.context.filesDir}/profile.json`);
   const check: CoreResponse = JSON.parse(await bridge.check(config)) as CoreResponse;
   if (!check.ok) { throw new Error(check.message); }
   retryable = true;
   this.requireAlive();
   this.status.physicalInterface = await this.physicalNetwork();
   this.requireAlive();
   if (this.bypassCurrentWifi) {
    this.registerNetConnection();
    this.publish('paused', '已进入指定 Wi-Fi，VPN 已暂停；离开后恢复');
    this.registerNetConnection();
    this.networkTimer = setInterval(() => { this.tick(); }, 3000);
    return;
   }
   this.conn = vpnExtension.createVpnConnection(this.context);
   const fd: number = await this.conn.create(this.makeConfig());
   this.requireAlive();
   this.status.tunName = bridge.tunName(fd);
   await this.confirmRoutes();
   this.requireAlive();
   // API 22+. Never start the core when loop protection fails.
   await this.conn.protectProcessNet();
   this.requireAlive();
   const addresses: InterfaceAddress[] = JSON.parse(bridge.interfaces()) as InterfaceAddress[];
   this.status.ipv6AddressPresent = addresses.some((it: InterfaceAddress): boolean => it.name === this.status.tunName && it.family === 6 && it.address === 'fdfe:dcba:9876::1');
   if (!this.status.ipv6AddressPresent) { throw new Error('系统未给 TUN 分配预期 IPv6 地址'); }
   const network: string = JSON.stringify(this.networkState);
   const result: CoreResponse = JSON.parse(await bridge.start(config, fd, this.context.filesDir, this.status.physicalInterface, this.status.tunName, this.physicalNetId, network)) as CoreResponse;
   if (!result.ok) { if (result.errorCode?.startsWith('wg-')) { startupHint = result.message; } throw new Error('内核启动未完成'); }
   this.lastSentNetwork = network;
   this.lastAppliedSsidPolicy = '';
   this.clockJump.reset(Date.now());
   this.selfHeal.reset();
   writePrivate(`${this.context.filesDir}/running-profile.json`, config);
   this.requireAlive();
   await this.applySsidPolicy();
   this.requireAlive();
   this.registerNetConnection();
   this.startUdsServer();
   this.publish('running', SingboxVpnAbility.RUNNING_MESSAGE);
   this.networkTimer = setInterval(() => { this.tick(); }, 1000);
  } catch (_error) {
   await this.cleanup();
   if (this.destroyed) { return; }
   if (retryable && loadSettings(this.context.filesDir).autoReconnect) {
    recordInterruption(this.context.filesDir, startupHint || '连接暂不可用');
    this.publish('reconnecting', startupHint ? `${startupHint}，正在重试` : '连接暂不可用，正在等待网络恢复');
    this.networkTimer = setInterval(() => { this.tick(); }, 3000);
   } else {
    recordInterruption(this.context.filesDir, 'VPN 启动失败');
    this.publish('error', 'VPN 启动失败，请检查配置和当前网络');
    await this.stopSelf();
   }
  }
 }
 private async inspectBlackholeRecovery(): Promise<void> {
  try {
   const name: string = await this.physicalNetwork();
   if (this.destroyed) { return; }
   this.blackholeSince = 0;
   if (this.bypassCurrentWifi) {
    await this.cleanup();
    if (this.destroyed) { return; }
    this.publish('paused', '已进入指定 Wi-Fi，VPN 已暂停；离开后恢复');
    this.registerNetConnection();
    this.networkTimer = setInterval(() => { this.tick(); }, 3000);
    return;
   }
   const handedOver: boolean = await this.trySoftHandover(name);
   if (this.destroyed) { return; }
   if (handedOver) {
    await this.applySsidPolicy();
    return;
   }
   await this.cleanup();
   if (this.destroyed) { return; }
   await this.recoverNetwork('网络已切换');
  } catch (error) {
   if (this.destroyed) { return; }
   const noPhysicalNet: boolean = error instanceof Error && error.message === '没有可用的物理网络';
   if (noPhysicalNet && Date.now() - this.blackholeSince < SingboxVpnAbility.BLACKHOLE_MAX_MS) {
    this.publish('reconnecting', '网络暂时中断，已保持 TUN 防泄漏，等待恢复');
    return;
   }
   this.blackholeSince = 0;
   await this.cleanup();
   if (this.destroyed) { return; }
   await this.recoverNetwork('物理网络不可用');
  }
 }
 private async inspectNetwork(): Promise<void> {
  if (this.checkingNetwork || this.destroyed) { return; }
  this.checkingNetwork = true;
  try {
   if (this.blackholeSince > 0 && this.conn !== undefined) {
    this.syncUdsTimer();
    if (await this.processUdsControl()) { return; }
    if (await this.processControl()) { return; }
    await this.inspectBlackholeRecovery();
    return;
   }
   if (this.status.phase === 'reconnecting') { await this.startVpn(); return; }
   if (this.status.phase === 'paused') {
    await this.physicalNetwork(); if (this.destroyed) { return; }
    if (this.bypassCurrentWifi) { this.publish('paused', this.status.message); } else { await this.startVpn(); }
    return;
   }
   this.syncUdsTimer();
   if (await this.processUdsControl()) { return; }
   if (await this.processControl()) { return; }
   const intervalMs: number = this.inspectIntervalMs();
   const nowMs: number = Date.now();
   if (nowMs - this.lastNetworkInspect < intervalMs) { return; }
   this.lastNetworkInspect = nowMs;

   if (this.clockJump.observe(nowMs, intervalMs)) {
    recordSelfHeal(this.context.filesDir);
    try { await bridge.control('{"action":"reset-network"}'); } catch (_error) {}
    if (this.destroyed) { return; }
   }

   const previousNetId: number = this.physicalNetId;
   const name: string = await this.physicalNetwork();
   if (this.destroyed) { return; }
   if (this.bypassCurrentWifi) {
    await this.cleanup();
    if (this.destroyed) { return; }
    this.publish('paused', '已进入指定 Wi-Fi，VPN 已暂停；离开后恢复');
    this.registerNetConnection();
    this.networkTimer = setInterval(() => { this.tick(); }, 3000);
    return;
   }
   if (name !== this.status.physicalInterface || previousNetId !== this.physicalNetId) {
    const handedOver: boolean = await this.trySoftHandover(name);
    if (this.destroyed) { return; }
    if (handedOver) {
     await this.applySsidPolicy();
    } else {
     await this.cleanup();
     if (this.destroyed) { return; }
     await this.recoverNetwork('网络已切换');
    }
   } else {
    const network: string = JSON.stringify(this.networkState);
    if (network !== this.lastSentNetwork) {
     const reply: CoreResponse = JSON.parse(await bridge.control(JSON.stringify({ action: 'wifi-state', network: this.networkState }))) as CoreResponse;
     if (!reply.ok) { throw new Error('Wi-Fi 条件同步未完成'); }
     this.lastSentNetwork = network;
    }
    await this.applySsidPolicy();
    if (this.destroyed) { return; }
    const stats: CoreStats = JSON.parse(await bridge.stats()) as CoreStats;
    if (this.destroyed) { return; }
    this.status.uplink = stats.uplink; this.status.downlink = stats.downlink; this.status.ipv4Flows = stats.ipv4Flows; this.status.ipv6Flows = stats.ipv6Flows;
    this.status.bindSuccess = stats.bindSuccess; this.status.bindFailure = stats.bindFailure; this.status.lastBindError = stats.lastBindError;
    this.status.dnsError = stats.dnsError;
    const healAction: SelfHealAction = this.selfHeal.observe(stats.bindFailure || 0, stats.dnsError || '');
    if (healAction === 'reset') {
     recordSelfHeal(this.context.filesDir);
     try { await bridge.control('{"action":"reset-network"}'); } catch (_error) {}
     if (this.destroyed) { return; }
    } else if (healAction === 'rebuild') {
     recordSelfHeal(this.context.filesDir);
     await this.cleanup();
     if (this.destroyed) { return; }
     await this.recoverNetwork('连接异常自愈重建');
     return;
    }
    this.publish('running', this.status.message);
    await this.snapshotDashboard();
   }
  } catch (error) {
   if (this.destroyed) { return; }
   const noPhysicalNet: boolean = error instanceof Error && error.message === '没有可用的物理网络';
   if (noPhysicalNet && this.status.phase === 'running' && this.conn !== undefined && this.isBlackholeEnabled()) {
    this.blackholeSince = Date.now();
    this.publish('reconnecting', '网络暂时中断，已保持 TUN 防泄漏，等待恢复');
    return;
   }
   await this.cleanup();
   if (this.destroyed) { return; }
   await this.recoverNetwork('物理网络不可用');
  } finally { this.checkingNetwork = false; }
 }
 private async recoverNetwork(message: string): Promise<void> {
  recordInterruption(this.context.filesDir, message);
  if (loadSettings(this.context.filesDir).autoReconnect) {
   this.publish('reconnecting', `${message}，正在重新连接`);
   this.networkTimer = setInterval(() => { this.tick(); }, 3000);
  } else {
   this.publish('error', `${message}，请重新连接 VPN`);
   await this.stopSelf();
  }
 }
 private udsSocketPath(): string {
  return `${this.context.filesDir}/control.sock`;
 }
 private startUdsServer(): void {
  if (this.udsServerFd >= 0 || this.destroyed) { return; }
  try {
   if (typeof bridge.udsListen === 'function') {
    this.udsServerFd = bridge.udsListen(this.udsSocketPath());
   }
  } catch (_error) {
   this.udsServerFd = -1;
  }
  if (this.udsServerFd >= 0) {
   this.syncUdsTimer();
  }
 }
 private syncUdsTimer(): void {
  if (this.destroyed || this.udsServerFd < 0) {
   if (this.udsTimer !== -1) {
    clearInterval(this.udsTimer);
    this.udsTimer = -1;
    this.udsTimerMs = 0;
   }
   return;
  }
  const desiredMs: number = this.uiActive() ? 120 : 600;
  if (this.udsTimer !== -1 && this.udsTimerMs === desiredMs) { return; }
  if (this.udsTimer !== -1) {
   clearInterval(this.udsTimer);
   this.udsTimer = -1;
  }
  this.udsTimerMs = desiredMs;
  this.udsTimer = setInterval(() => { this.pollUds(); }, desiredMs);
 }
 private stopUdsServer(): void {
  if (this.udsTimer !== -1) {
   clearInterval(this.udsTimer);
   this.udsTimer = -1;
   this.udsTimerMs = 0;
  }
  if (this.udsServerFd >= 0) {
   const fd: number = this.udsServerFd;
   this.udsServerFd = -1;
   try {
    if (typeof bridge.udsClose === 'function') {
     bridge.udsClose(fd, this.udsSocketPath());
    }
   } catch (_error) {}
  }
 }
 private pollUds(): void {
  if (this.destroyed || this.udsServerFd < 0 || this.processingUds || typeof bridge.udsAcceptRead !== 'function') { return; }
  let raw: string = '';
  try { raw = bridge.udsAcceptRead(this.udsServerFd); } catch (_error) { return; }
  if (!raw || raw.length === 0) { return; }
  this.processingUds = true;
  this.task = this.task.catch(() => {}).then(async () => {
   try {
    await this.handleUdsPayload(raw);
    await this.drainUdsControl();
   } finally {
    this.processingUds = false;
   }
  });
 }
 private async processUdsControl(): Promise<boolean> {
  if (this.destroyed || this.udsServerFd < 0 || this.processingUds || typeof bridge.udsAcceptRead !== 'function') { return false; }
  this.processingUds = true;
  try {
   return await this.drainUdsControl();
  } finally {
   this.processingUds = false;
  }
 }
 private async drainUdsControl(): Promise<boolean> {
  let reconnected: boolean = false;
  for (let i: number = 0; i < 4; i++) {
   if (this.destroyed || this.udsServerFd < 0 || typeof bridge.udsAcceptRead !== 'function') { break; }
   let raw: string = '';
   try { raw = bridge.udsAcceptRead(this.udsServerFd); } catch (_error) { break; }
   if (!raw || raw.length === 0) { break; }
   if (await this.handleUdsPayload(raw)) {
    reconnected = true;
    break;
   }
  }
  return reconnected;
 }
 private async handleUdsPayload(raw: string): Promise<boolean> {
  let envelope: UdsEnvelope;
  try { envelope = JSON.parse(raw) as UdsEnvelope; } catch (_error) { return false; }
  if (typeof envelope.fd !== 'number' || envelope.fd < 0) { return false; }
  let request: ControlRequest | undefined;
  try { request = JSON.parse(envelope.payload) as ControlRequest; } catch (_error) { request = undefined; }
  if (!request || !request.id || (typeof request.createdAt === 'number' && (Date.now() - request.createdAt > 6000 || request.createdAt > Date.now() + 1000))) {
   const invalid: ControlResult = { id: request?.id || '', ok: false, message: '无效的控制请求' };
   try { if (typeof bridge.udsWriteClose === 'function') { bridge.udsWriteClose(envelope.fd, JSON.stringify(invalid)); } } catch (_error) {}
   return false;
  }
  this.lastControlId = request.id;
  let result: ControlResult;
  try {
   result = await this.executeControlRequest(request);
  } catch (error) {
   const message: string = error instanceof Error ? error.message : '控制请求执行失败';
   result = { id: request.id, ok: false, message: message };
  }
  try {
   if (typeof bridge.udsWriteClose === 'function') {
    bridge.udsWriteClose(envelope.fd, JSON.stringify(result));
   }
  } catch (_error) {}
  return request.action === 'reconnect';
 }
 private async executeControlRequest(request: ControlRequest): Promise<ControlResult> {
  let reply: ControlReply;
  if (request.action === 'ping') {
   if (this.status.phase === 'running') {
    try {
     const stats: CoreStats = JSON.parse(await bridge.stats()) as CoreStats;
     if (!this.destroyed) {
      this.status.uplink = stats.uplink; this.status.downlink = stats.downlink;
      this.status.ipv4Flows = stats.ipv4Flows; this.status.ipv6Flows = stats.ipv6Flows;
      this.status.bindSuccess = stats.bindSuccess; this.status.bindFailure = stats.bindFailure;
      this.status.lastBindError = stats.lastBindError; this.status.dnsError = stats.dnsError;
     }
    } catch (_error) {}
   }
   if (!this.destroyed) { this.publish(this.status.phase, this.status.message, true); }
   reply = { ok: true, message: 'ok' };
  } else if (request.action === 'reconnect') {
   await this.cleanup();
   if (this.destroyed) { return { id: request.id, ok: false, message: 'VPN 已停止' }; }
   await this.startVpn();
   reply = { ok: this.status.phase === 'running', message: this.status.phase === 'running' ? '已重新连接' : '正在等待网络恢复' };
  } else {
   const nativeRequest: NativeControlRequest = { action: request.action, group: request.group || '', outbound: request.outbound || '', id: request.connectionId || '', mode: request.mode || '', host: request.host || '' };
   reply = JSON.parse(await bridge.control(JSON.stringify(nativeRequest))) as ControlReply;
  }
  const result: ControlResult = { id: request.id, ok: reply.ok, message: reply.message };
  if (reply.diagnosis) { result.diagnosis = reply.diagnosis; }
  if (reply.deepProbe) { result.deepProbe = reply.deepProbe; }
  if (reply.converted !== undefined) { result.converted = reply.converted; }
  this.lastSnapshotAt = 0;
  return result;
 }
 private async processControl(): Promise<boolean> {
  let request: ControlRequest;
  try { request = JSON.parse(readPrivate(`${this.context.filesDir}/control-request.json`)) as ControlRequest; } catch (_error) { return false; }
  if (!request.id || request.id === this.lastControlId) { return false; }
  this.lastControlId = request.id;
  if (Date.now() - request.createdAt > 6000 || request.createdAt > Date.now() + 1000) { return false; }
  const result: ControlResult = await this.executeControlRequest(request);
  if (this.destroyed) { return true; }
  writePrivate(`${this.context.filesDir}/control-result.json`, JSON.stringify(result));
  return request.action === 'reconnect';
 }
 private async snapshotDashboard(): Promise<void> {
  if (Date.now() - this.lastSnapshotAt < 2000) { return; }
  try {
   const demand: DashboardDemand = JSON.parse(readPrivate(`${this.context.filesDir}/dashboard-demand.json`)) as DashboardDemand;
   if (Date.now() - demand.updatedAt > 10000) { return; }
  } catch (_error) { return; }
  const reply: ControlReply = JSON.parse(await bridge.control('{"action":"snapshot"}')) as ControlReply;
  if (this.destroyed) { return; }
  if (reply.ok && reply.data) { writePrivate(`${this.context.filesDir}/dashboard.json`, JSON.stringify(reply.data)); }
  this.lastSnapshotAt = Date.now();
 }
 private async stopSelf(): Promise<void> {
  try { await vpnExtension.stopVpnExtensionAbility({ bundleName: BUNDLE_NAME, abilityName: VPN_ABILITY }); } catch (_error) {}
 }
 private async cleanup(): Promise<void> {
  this.blackholeSince = 0;
  this.lastAppliedSsidPolicy = '';
  this.unregisterNetConnection();
  this.stopUdsServer();
  if (this.networkTimer !== -1) { clearInterval(this.networkTimer); this.networkTimer = -1; }
  try { await bridge.stop(); } catch (_error) {}
  if (this.conn) { try { await this.conn.destroy(); } catch (_error) {} this.conn = undefined; }
 }
}

interface NativeControlRequest { action: string; group: string; outbound: string; id: string; mode: string; host: string; }
interface ModeControlRequest { action: string; mode: string; }
interface SelectControlRequest { action: string; group: string; outbound: string; }
interface UpdatePhysicalNetRequest { action: string; interfaceName: string; netId: number; network: PhysicalNetworkState; }
interface DashboardDemand { updatedAt: number; }
interface UdsEnvelope { fd: number; payload: string; }
