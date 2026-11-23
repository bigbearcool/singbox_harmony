import fs from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

let env;
let fakeNow = 1_700_000_000_000;
const files = new Map();
const intervals = new Set();
const timeouts = new Map();
let nextTimeoutId = 1;

const originalDateNow = Date.now;
const originalSetInterval = globalThis.setInterval;
const originalClearInterval = globalThis.clearInterval;
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;

Date.now = () => fakeNow;
globalThis.setInterval = (cb, ms) => {
  const token = { cb, ms };
  intervals.add(token);
  return token;
};
globalThis.clearInterval = (token) => {
  intervals.delete(token);
};
globalThis.setTimeout = (cb, ms = 0) => {
  const id = nextTimeoutId++;
  timeouts.set(id, { cb, at: fakeNow + ms, ms });
  return id;
};
globalThis.clearTimeout = (id) => {
  timeouts.delete(id);
};

function advanceTime(ms) {
  fakeNow += ms;
  const due = [];
  for (const [id, entry] of timeouts.entries()) {
    if (entry.at <= fakeNow) {
      due.push([id, entry]);
    }
  }
  due.sort((a, b) => a[1].at - b[1].at);
  for (const [id, entry] of due) {
    if (timeouts.has(id)) {
      timeouts.delete(id);
      entry.cb();
    }
  }
}

const initialStatus = () => ({
  phase: 'stopped',
  message: 'stopped',
  tunName: '',
  physicalInterface: '',
  ipv6AddressPresent: false,
  updatedAt: fakeNow
});

const readPrivate = (path) => {
  if (files.has(path)) return files.get(path);
  if (path.endsWith('profile.json')) return '{}';
  throw new Error('absent');
};
const writePrivate = (path, value) => {
  files.set(path, value);
  if (path.endsWith('vpn-status.json')) {
    env.phases.push(JSON.parse(value).phase);
  }
};

globalThis.__aoWifiEnv = {
  util: { TextEncoder: class { encodeInto(v) { return new TextEncoder().encode(v); } } },
  wifiManager: {
    getLinkedInfo: async () => {
      if (env.wifiReadFails) throw new Error('201');
      return { ssid: env.ssid || '' };
    }
  }
};
const wifiSource = fs.readFileSync(new URL('../entry/src/main/ets/common/WifiConditions.ets', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
const { observeWifi, wifiPauseDecision } = await import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes('const {util,wifiManager}=globalThis.__aoWifiEnv;\n' + wifiSource, { mode: 'strip' })).toString('base64'));

globalThis.__aoEnv = { readPrivate, writePrivate };
const alwaysOnSource = fs.readFileSync(new URL('../entry/src/main/ets/common/AlwaysOn.ets', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
const AlwaysOn = await import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes('const {readPrivate,writePrivate}=globalThis.__aoEnv;\n' + alwaysOnSource, { mode: 'strip' })).toString('base64'));
const {
  ClockJumpDetector,
  SelfHealTracker,
  HandoverDebouncer,
  loadDesiredState,
  saveDesiredState,
  recordInterruption,
  recordHandover,
  recordSelfHeal
} = AlwaysOn;

const connection = {
  NetBearType: { BEARER_VPN: 4, BEARER_CELLULAR: 0, BEARER_WIFI: 1 },
  NetCap: { NET_CAPABILITY_INTERNET: 12 },
  createNetConnection: () => {
    if (env.noNetConnection) {
      throw new Error('not supported');
    }
    const listeners = new Map();
    const handle = {
      listeners,
      registered: false,
      unregistered: false,
      on(event, cb) {
        listeners.set(event, cb);
      },
      register(cb) {
        handle.registered = true;
        env.netConnRegisterCalls++;
        if (cb) cb(undefined);
      },
      unregister(cb) {
        handle.unregistered = true;
        env.netConnUnregisterCalls++;
        if (cb) cb(undefined);
      },
      emit(event) {
        const fn = listeners.get(event);
        if (fn) fn({});
      }
    };
    env.netConns.push(handle);
    return handle;
  },
  getDefaultNet: async () => {
    env.physicalProbes++;
    if (env.noPhysicalNet) {
      return { netId: 2 };
    }
    return { netId: env.netId };
  },
  getAllNets: async () => {
    if (env.noPhysicalNet) {
      return env.vpn ? [{ netId: 2 }] : [];
    }
    return env.vpn ? [{ netId: env.netId }, { netId: 2 }] : [{ netId: env.netId }];
  },
  getNetCapabilities: async (net) => {
    if (net.netId === 2) {
      return { bearerTypes: [4], networkCap: [12] };
    }
    return { bearerTypes: [env.kind === 'wifi' ? 1 : 0], networkCap: [12] };
  },
  getConnectionProperties: async (net) => {
    if (net.netId === 2) {
      return {
        interfaceName: 'vpn-tun',
        linkAddresses: [{ address: { address: '172.19.0.1' } }, { address: { address: 'fdfe:dcba:9876::1' } }],
        routes: [
          { destination: { address: { address: '0.0.0.0' }, prefixLength: 0 } },
          { destination: { address: { address: '::' }, prefixLength: 0 } }
        ]
      };
    }
    return {
      interfaceName: env.iface,
      linkAddresses: [{ address: { family: 2, address: '2001:db8::1' } }]
    };
  }
};

const bridge = {
  check: async () => '{"ok":true}',
  tunName: () => 'vpn-tun',
  interfaces: () => JSON.stringify([{ name: 'vpn-tun', family: 6, address: 'fdfe:dcba:9876::1' }]),
  control: async (input) => {
    const parsed = JSON.parse(input);
    env.controls.push(parsed);
    if (parsed.action === 'update-physical-net') {
      if (env.handoverThrows) throw new Error('bridge error');
      if (env.handoverFails) return '{"ok":false,"message":"handover unsupported"}';
    }
    return '{"ok":true}';
  },
  start: async () => {
    env.startCalls++;
    env.core = true;
    return '{"ok":true}';
  },
  stop: async () => {
    env.stopCalls++;
    env.core = false;
  },
  stats: async () => JSON.stringify({
    uplink: 100,
    downlink: 200,
    ipv4Flows: 1,
    ipv6Flows: 0,
    bindSuccess: 5,
    bindFailure: env.bindFailure,
    lastBindError: env.bindFailure > 0 ? 'EPERM' : '',
    dnsError: env.dnsError
  })
};

globalThis.__aoVpnEnv = {
  observeWifi,
  wifiPauseDecision,
  ClockJumpDetector,
  SelfHealTracker,
  HandoverDebouncer,
  loadDesiredState,
  saveDesiredState,
  recordInterruption,
  recordHandover,
  recordSelfHeal,
  applyVpnScope: (config) => config,
  loadVpnScope: () => ({ mode: 'all', applications: [] }),
  VpnExtensionAbility: class { context = { filesDir: '/test' }; },
  connection,
  bridge,
  vpnExtension: {
    createVpnConnection: () => ({
      create: async () => { env.createCalls++; env.vpn = true; return 42; },
      protectProcessNet: async () => {},
      destroy: async () => { env.destroyCalls++; env.vpn = false; }
    }),
    stopVpnExtensionAbility: async () => { env.stopSelfCalls++; }
  },
  loadSettings: () => {
    const s = {
      autoReconnect: env.autoReconnect,
      onDemand: false,
      bypassWifi: []
    };
    if (env.blackholeOnSwitch !== undefined) {
      s.blackholeOnSwitch = env.blackholeOnSwitch;
    }
    return s;
  },
  BUNDLE_NAME: 'com.bigbear.singbox',
  VPN_ABILITY: 'SingboxVpnAbility',
  readPrivate,
  writePrivate,
  initialStatus,
  hilog: { info() {}, warn() {} }
};

const vpnSource = fs.readFileSync(new URL('../entry/src/main/ets/vpn/SingboxVpnAbility.ets', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
const { default: SingboxVpnAbility } = await import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes(
  'const {observeWifi,wifiPauseDecision,ClockJumpDetector,SelfHealTracker,HandoverDebouncer,loadDesiredState,saveDesiredState,recordInterruption,recordHandover,recordSelfHeal,applyVpnScope,loadVpnScope,VpnExtensionAbility,connection,bridge,vpnExtension,loadSettings,BUNDLE_NAME,VPN_ABILITY,readPrivate,writePrivate,initialStatus,hilog}=globalThis.__aoVpnEnv;\n' + vpnSource,
  { mode: 'strip' }
)).toString('base64'));

function resetEnv(overrides = {}) {
  fakeNow = 1_700_000_000_000;
  files.clear();
  intervals.clear();
  timeouts.clear();
  env = {
    vpn: false,
    core: false,
    kind: 'wifi',
    ssid: 'OfficeWiFi',
    iface: 'wlan0',
    netId: 1,
    noPhysicalNet: false,
    noNetConnection: false,
    autoReconnect: true,
    blackholeOnSwitch: undefined,
    handoverFails: false,
    handoverThrows: false,
    bindFailure: 0,
    dnsError: '',
    createCalls: 0,
    startCalls: 0,
    stopCalls: 0,
    destroyCalls: 0,
    stopSelfCalls: 0,
    physicalProbes: 0,
    netConnRegisterCalls: 0,
    netConnUnregisterCalls: 0,
    netConns: [],
    phases: [],
    controls: [],
    ...overrides
  };
}

test('AlwaysOn: DesiredVpnState persistence and recordInterruption guard', () => {
  resetEnv();
  const def = loadDesiredState('/test');
  assert.equal(def.desired, 'stopped');
  assert.equal(def.handoverCount, 0);

  // Corrupted file returns safe default
  files.set('/test/desired-state.json', '{bad json');
  assert.equal(loadDesiredState('/test').desired, 'stopped');

  // recordInterruption is ignored when desired === 'stopped'
  saveDesiredState('/test', { desired: 'stopped', updatedAt: fakeNow });
  recordInterruption('/test', 'unexpected drop');
  assert.equal(loadDesiredState('/test').lastInterruptionReason, undefined);

  // recordInterruption persists when desired === 'connected'
  saveDesiredState('/test', { desired: 'connected', updatedAt: fakeNow });
  advanceTime(5000);
  recordInterruption('/test', 'network lost');
  const loaded = loadDesiredState('/test');
  assert.equal(loaded.desired, 'connected');
  assert.equal(loaded.lastInterruptionReason, 'network lost');
  assert.equal(loaded.lastInterruptionAt, fakeNow);

  assert.equal(recordHandover('/test'), 1);
  assert.equal(recordHandover('/test'), 2);
  assert.equal(recordSelfHeal('/test'), 1);
  const after = loadDesiredState('/test');
  assert.equal(after.handoverCount, 2);
  assert.equal(after.selfHealCount, 1);
});

test('AlwaysOn: ClockJumpDetector detects deep sleep wakeup', () => {
  const detector = new ClockJumpDetector();
  assert.equal(detector.observe(1000, 15000), false);
  assert.equal(detector.observe(16000, 15000), false);
  assert.equal(detector.observe(106000, 15000), false); // exactly 90000ms -> not > 90000
  assert.equal(detector.observe(196001, 15000), true);  // 90001ms > max(45000, 90000)
  assert.equal(detector.observe(211001, 15000), false);
  // Larger expected interval: threshold = max(40000 * 3, 90000) = 120000
  assert.equal(detector.observe(331001, 40000), false);
  assert.equal(detector.observe(451002, 40000), true);
});

test('AlwaysOn: SelfHealTracker escalates reset -> rebuild and resets on healthy stats', () => {
  const tracker = new SelfHealTracker();
  assert.equal(tracker.observe(0, ''), 'none');
  // Faults via dnsError: 2 faults -> reset, 4 -> reset, 6 -> rebuild
  assert.equal(tracker.observe(0, 'timeout'), 'none');
  assert.equal(tracker.observe(0, 'timeout'), 'reset');
  assert.equal(tracker.observe(0, 'timeout'), 'none');
  assert.equal(tracker.observe(0, 'timeout'), 'reset');
  assert.equal(tracker.observe(0, 'timeout'), 'none');
  assert.equal(tracker.observe(0, 'timeout'), 'rebuild');

  // Faults via increasing bindFailure
  assert.equal(tracker.observe(1, ''), 'none');
  assert.equal(tracker.observe(2, ''), 'reset');
  // Healthy tick clears counters
  assert.equal(tracker.observe(2, ''), 'none');
  assert.equal(tracker.observe(3, ''), 'none');
});

test('AlwaysOn: HandoverDebouncer coalesces rapid events and supports cancel', () => {
  resetEnv();
  const debouncer = new HandoverDebouncer(450);
  let calls = 0;
  debouncer.schedule(() => { calls++; });
  advanceTime(200);
  debouncer.schedule(() => { calls++; });
  advanceTime(200);
  debouncer.schedule(() => { calls++; });
  advanceTime(449);
  assert.equal(calls, 0);
  assert.equal(debouncer.isPending(), true);
  advanceTime(1);
  assert.equal(calls, 1);
  assert.equal(debouncer.isPending(), false);

  // Cancel prevents firing
  debouncer.schedule(() => { calls++; });
  advanceTime(100);
  debouncer.cancel();
  advanceTime(1000);
  assert.equal(calls, 1);
});

test('SingboxVpnAbility: Soft Handover succeeds without tearing down TUN', async () => {
  resetEnv();
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;
  assert.equal(ability.status.phase, 'running');
  assert.equal(ability.status.physicalInterface, 'wlan0');
  assert.equal(env.createCalls, 1);

  // Switch from Wi-Fi wlan0 (netId 1) to Cellular rmnet0 (netId 3)
  env.kind = 'cellular';
  env.iface = 'rmnet0';
  env.netId = 3;
  advanceTime(16000);
  ability.tick();
  await ability.task;

  const handoverReq = env.controls.find((c) => c.action === 'update-physical-net');
  assert.ok(handoverReq, 'expected update-physical-net control call');
  assert.equal(handoverReq.interfaceName, 'rmnet0');
  assert.equal(handoverReq.netId, 3);
  assert.equal(handoverReq.network.type, 'cellular');
  assert.equal(env.destroyCalls, 0, 'TUN must NOT be destroyed on soft handover');
  assert.equal(env.stopCalls, 0, 'core must NOT be stopped on soft handover');
  assert.equal(ability.status.physicalInterface, 'rmnet0');
  assert.equal(ability.status.phase, 'running');
  assert.equal(loadDesiredState('/test').handoverCount, 1);

  ability.onDestroy();
  await ability.task;
});

test('SingboxVpnAbility: Soft Handover failure falls back to cleanup and rebuild', async () => {
  resetEnv({ handoverFails: true, autoReconnect: true });
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  env.kind = 'cellular';
  env.iface = 'rmnet0';
  env.netId = 3;
  advanceTime(16000);
  ability.tick();
  await ability.task;

  assert.equal(env.destroyCalls, 1);
  assert.equal(env.stopCalls, 1);
  assert.equal(ability.status.phase, 'reconnecting');
  assert.equal(loadDesiredState('/test').lastInterruptionReason, '网络已切换');

  ability.onDestroy();
  await ability.task;
});

test('SingboxVpnAbility: Blackhole protection keeps TUN alive and recovers via soft handover', async () => {
  resetEnv({ autoReconnect: true });
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  // Network drops completely
  env.noPhysicalNet = true;
  advanceTime(16000);
  ability.tick();
  await ability.task;

  assert.equal(env.vpn, true, 'TUN stays alive during blackhole protection');
  assert.equal(env.destroyCalls, 0);
  assert.equal(env.stopCalls, 0);
  assert.equal(ability.status.phase, 'reconnecting');
  assert.match(ability.status.message, /防泄漏/);

  // Still absent 30s later -> still keeping TUN
  advanceTime(30000);
  ability.tick();
  await ability.task;
  assert.equal(env.destroyCalls, 0);
  assert.equal(env.vpn, true);

  // Network returns on cellular before 60s -> soft handover recovers with 0 TUN teardown
  env.noPhysicalNet = false;
  env.kind = 'cellular';
  env.iface = 'rmnet0';
  env.netId = 4;
  advanceTime(5000);
  ability.tick();
  await ability.task;

  assert.equal(env.destroyCalls, 0);
  assert.equal(ability.status.phase, 'running');
  assert.equal(ability.status.physicalInterface, 'rmnet0');

  ability.onDestroy();
  await ability.task;
});

test('SingboxVpnAbility: Blackhole protection times out after 60s and respects autoReconnect', async () => {
  resetEnv({ autoReconnect: false });
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  env.noPhysicalNet = true;
  advanceTime(16000);
  ability.tick();
  await ability.task;
  assert.equal(env.destroyCalls, 0);
  assert.equal(ability.status.phase, 'reconnecting');

  // Advance past 60s blackhole limit
  advanceTime(61000);
  ability.tick();
  await ability.task;

  assert.equal(env.destroyCalls, 1);
  assert.equal(env.stopCalls, 1);
  assert.equal(ability.status.phase, 'error');
  assert.equal(env.stopSelfCalls, 1);

  ability.onDestroy();
  await ability.task;
});

test('SingboxVpnAbility: blackholeOnSwitch=false disables blackhole protection', async () => {
  resetEnv({ blackholeOnSwitch: false, autoReconnect: true });
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  env.noPhysicalNet = true;
  advanceTime(16000);
  ability.tick();
  await ability.task;

  assert.equal(env.destroyCalls, 1);
  assert.equal(env.stopCalls, 1);
  assert.equal(ability.status.phase, 'reconnecting');

  ability.onDestroy();
  await ability.task;
});

test('SingboxVpnAbility: Clock jump triggers reset-network and SelfHealTracker escalates', async () => {
  resetEnv({ autoReconnect: true });
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  // Simulate 120s deep sleep
  advanceTime(120000);
  ability.tick();
  await ability.task;

  assert.ok(env.controls.some((c) => c.action === 'reset-network'), 'deep sleep wakeup should send reset-network');
  assert.equal(loadDesiredState('/test').selfHealCount, 1);

  // Inject persistent DNS error -> 2 ticks triggers reset, 6 ticks triggers rebuild
  env.controls = [];
  env.dnsError = 'i/o timeout';
  for (let i = 0; i < 2; i++) {
    advanceTime(16000);
    ability.tick();
    await ability.task;
  }
  assert.equal(env.controls.filter((c) => c.action === 'reset-network').length, 1);
  assert.equal(env.destroyCalls, 0);

  for (let i = 0; i < 4; i++) {
    advanceTime(16000);
    ability.tick();
    await ability.task;
  }
  assert.equal(env.destroyCalls, 1, '3rd escalation should rebuild VPN');
  assert.equal(ability.status.phase, 'reconnecting');

  ability.onDestroy();
  await ability.task;
});

test('SingboxVpnAbility: NetConnection events debounce handover, 15s background throttle, and cleanup unregisters', async () => {
  resetEnv();
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  assert.equal(env.netConnRegisterCalls, 1);
  const netCon = env.netConns[0];
  assert.ok(netCon.listeners.has('netAvailable'));
  assert.ok(netCon.listeners.has('netLost'));
  assert.ok(netCon.listeners.has('netCapabilitiesChange'));
  assert.ok(netCon.listeners.has('netConnectionPropertiesChange'));

  // Background throttle is 15s: tick at +5s should NOT probe physical network
  ability.lastNetworkInspect = fakeNow;
  const probesBefore = env.physicalProbes;
  advanceTime(5000);
  ability.tick();
  await ability.task;
  assert.equal(env.physicalProbes, probesBefore, 'background tick at 5s must be throttled to 15s');

  // Burst of NetConnection events coalesces via 450ms debouncer and bypasses 15s throttle
  env.kind = 'cellular';
  env.iface = 'rmnet0';
  env.netId = 5;
  netCon.emit('netLost');
  advanceTime(100);
  netCon.emit('netAvailable');
  advanceTime(100);
  netCon.emit('netCapabilitiesChange');
  advanceTime(449);
  assert.equal(env.controls.length, 0, 'debouncer should not fire before 450ms');
  advanceTime(1);
  await ability.task;
  assert.equal(env.controls.filter((c) => c.action === 'update-physical-net').length, 1);
  assert.equal(ability.status.physicalInterface, 'rmnet0');

  // Schedule another event, then destroy before 450ms -> debouncer cancelled & netCon unregistered
  netCon.emit('netConnectionPropertiesChange');
  ability.onDestroy();
  await ability.task;
  advanceTime(1000);
  assert.equal(env.netConnUnregisterCalls, 1);
  assert.equal(netCon.unregistered, true);
  assert.equal(intervals.size, 0);
});

test.after(() => {
  Date.now = originalDateNow;
  globalThis.setInterval = originalSetInterval;
  globalThis.clearInterval = originalClearInterval;
  globalThis.setTimeout = originalSetTimeout;
  globalThis.clearTimeout = originalClearTimeout;
  delete globalThis.__aoWifiEnv;
  delete globalThis.__aoEnv;
  delete globalThis.__aoVpnEnv;
});
