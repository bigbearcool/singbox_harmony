import fs from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

let fakeNow = 1_700_000_000_000;
let uuidSeq = 1;
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

function flushTimeouts(stepMs = 100) {
  fakeNow += stepMs;
  const due = [];
  for (const [id, entry] of timeouts.entries()) {
    if (entry.at <= fakeNow) due.push([id, entry]);
  }
  due.sort((a, b) => a[1].at - b[1].at);
  for (const [id, entry] of due) {
    if (timeouts.has(id)) {
      timeouts.delete(id);
      entry.cb();
    }
  }
}

const readPrivate = (path) => {
  if (files.has(path)) return files.get(path);
  if (path.endsWith('profile.json')) return '{}';
  throw new Error('absent');
};
const writePrivate = (path, value) => {
  files.set(path, value);
};

// --- Load Control.ets ---
let ctrlEnv = {};
const ctrlBridge = {
  control: async (input) => ctrlEnv.onControl(JSON.parse(input)),
  udsRequest: async (socketPath, payload, timeoutMs) => ctrlEnv.onUdsRequest(socketPath, payload, timeoutMs)
};
globalThis.__udsCtrlEnv = {
  util: { generateRandomUUID: () => `req-${uuidSeq++}` },
  bridge: ctrlBridge,
  readPrivate,
  writePrivate
};
const controlSource = fs
  .readFileSync(new URL('../entry/src/main/ets/common/Control.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '');
const Control = await import(
  'data:text/javascript;base64,' +
    Buffer.from(
      stripTypeScriptTypes(
        'const {util,bridge,readPrivate,writePrivate}=globalThis.__udsCtrlEnv;\n' + controlSource,
        { mode: 'strip' }
      )
    ).toString('base64')
);

// --- Load SingboxVpnAbility.ets ---
let vpnEnv = {};
const initialStatus = () => ({
  phase: 'stopped',
  message: 'stopped',
  tunName: '',
  physicalInterface: '',
  ipv6AddressPresent: false,
  updatedAt: fakeNow
});

globalThis.__udsWifiEnv = {
  util: { TextEncoder: class { encodeInto(v) { return new TextEncoder().encode(v); } } },
  wifiManager: { getLinkedInfo: async () => ({ ssid: 'OfficeWiFi' }) }
};
const wifiSource = fs
  .readFileSync(new URL('../entry/src/main/ets/common/WifiConditions.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '');
const { observeWifi, wifiPauseDecision, evaluateSsidPolicy } = await import(
  'data:text/javascript;base64,' +
    Buffer.from(
      stripTypeScriptTypes('const {util,wifiManager}=globalThis.__udsWifiEnv;\n' + wifiSource, { mode: 'strip' })
    ).toString('base64')
);

globalThis.__udsAoEnv = { readPrivate, writePrivate };
const alwaysOnSource = fs
  .readFileSync(new URL('../entry/src/main/ets/common/AlwaysOn.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '');
const AlwaysOn = await import(
  'data:text/javascript;base64,' +
    Buffer.from(
      stripTypeScriptTypes('const {readPrivate,writePrivate}=globalThis.__udsAoEnv;\n' + alwaysOnSource, {
        mode: 'strip'
      })
    ).toString('base64')
);

const vpnBridge = {
  check: async () => '{"ok":true}',
  tunName: () => 'vpn-tun',
  interfaces: () => JSON.stringify([{ name: 'vpn-tun', family: 6, address: 'fdfe:dcba:9876::1' }]),
  start: async () => {
    vpnEnv.startCalls++;
    vpnEnv.core = true;
    return '{"ok":true}';
  },
  stop: async () => {
    vpnEnv.stopCalls++;
    vpnEnv.core = false;
    return '{"ok":true}';
  },
  stats: async () =>
    JSON.stringify({
      uplink: 42,
      downlink: 84,
      ipv4Flows: 1,
      ipv6Flows: 1,
      bindSuccess: 3,
      bindFailure: 0,
      lastBindError: '',
      dnsError: ''
    }),
  control: async (input) => {
    const req = JSON.parse(input);
    vpnEnv.controls.push(req);
    if (req.action === 'deep-probe') {
      return JSON.stringify({
        ok: true,
        message: '探测完成',
        deepProbe: {
          directIp: '203.0.113.10',
          directLatencyMs: 18,
          proxyIp: '198.51.100.22',
          proxyLatencyMs: 65,
          natType: 'Full Cone',
          stunMapped: '198.51.100.22:41234',
          summary: '直连 18ms / 代理 65ms / Full Cone'
        }
      });
    }
    if (req.action === 'diagnose-host') {
      return JSON.stringify({
        ok: true,
        message: `${req.host} OK`,
        diagnosis: {
          host: req.host,
          ipv4: ['93.184.216.34'],
          ipv6: [],
          latencyMs: 12,
          mode: 'rule',
          summary: `${req.host} -> 93.184.216.34`
        }
      });
    }
    return JSON.stringify({ ok: true, message: `handled:${req.action}` });
  },
  udsListen: (socketPath) => {
    vpnEnv.udsListenCalls.push(socketPath);
    if (vpnEnv.udsListenThrows) throw new Error('EACCES');
    if (vpnEnv.udsListenFail) return -1;
    const fd = vpnEnv.nextServerFd++;
    vpnEnv.openServerFds.add(fd);
    return fd;
  },
  udsAcceptRead: (serverFd) => {
    vpnEnv.acceptCalls.push(serverFd);
    if (!vpnEnv.openServerFds.has(serverFd) || vpnEnv.incomingUds.length === 0) {
      return '';
    }
    return JSON.stringify(vpnEnv.incomingUds.shift());
  },
  udsWriteClose: (clientFd, payload) => {
    vpnEnv.udsReplies.push({ fd: clientFd, payload: JSON.parse(payload) });
  },
  udsClose: (fd, socketPath) => {
    vpnEnv.openServerFds.delete(fd);
    vpnEnv.udsCloseCalls.push({ fd, socketPath });
  }
};

const connection = {
  NetBearType: { BEARER_VPN: 4, BEARER_CELLULAR: 0, BEARER_WIFI: 1 },
  NetCap: { NET_CAPABILITY_INTERNET: 12 },
  createNetConnection: () => ({
    on() {},
    register(cb) { if (cb) cb(undefined); },
    unregister(cb) { if (cb) cb(undefined); }
  }),
  getDefaultNet: async () => ({ netId: 1 }),
  getAllNets: async () => (vpnEnv.vpn ? [{ netId: 1 }, { netId: 2 }] : [{ netId: 1 }]),
  getNetCapabilities: async (net) => ({ bearerTypes: [net.netId === 2 ? 4 : 1], networkCap: [12] }),
  getConnectionProperties: async (net) =>
    net.netId === 2
      ? {
          interfaceName: 'vpn-tun',
          linkAddresses: [{ address: { address: '172.19.0.1' } }, { address: { address: 'fdfe:dcba:9876::1' } }],
          routes: [
            { destination: { address: { address: '0.0.0.0' }, prefixLength: 0 } },
            { destination: { address: { address: '::' }, prefixLength: 0 } }
          ]
        }
      : {
          interfaceName: 'wlan0',
          linkAddresses: [{ address: { family: 2, address: '2001:db8::1' } }]
        }
};

globalThis.__udsVpnEnv = {
  observeWifi,
  wifiPauseDecision,
  evaluateSsidPolicy,
  ...AlwaysOn,
  applyVpnScope: (config) => config,
  loadVpnScope: () => ({ mode: 'all', applications: [] }),
  VpnExtensionAbility: class { context = { filesDir: '/test' }; },
  connection,
  bridge: vpnBridge,
  vpnExtension: {
    createVpnConnection: () => ({
      create: async () => { vpnEnv.vpn = true; return 42; },
      protectProcessNet: async () => {},
      destroy: async () => { vpnEnv.vpn = false; }
    }),
    stopVpnExtensionAbility: async () => {}
  },
  loadSettings: () => ({ autoReconnect: false, onDemand: false, bypassWifi: [], ssidPolicies: [] }),
  BUNDLE_NAME: 'com.bigbear.singbox',
  VPN_ABILITY: 'SingboxVpnAbility',
  readPrivate,
  writePrivate,
  initialStatus,
  hilog: { info() {}, warn() {} }
};

const vpnSource = fs
  .readFileSync(new URL('../entry/src/main/ets/vpn/SingboxVpnAbility.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '');
const { default: SingboxVpnAbility } = await import(
  'data:text/javascript;base64,' +
    Buffer.from(
      stripTypeScriptTypes(
        'const {observeWifi,wifiPauseDecision,evaluateSsidPolicy,ClockJumpDetector,SelfHealTracker,HandoverDebouncer,loadDesiredState,saveDesiredState,recordInterruption,recordHandover,recordSelfHeal,applyVpnScope,loadVpnScope,VpnExtensionAbility,connection,bridge,vpnExtension,loadSettings,BUNDLE_NAME,VPN_ABILITY,readPrivate,writePrivate,initialStatus,hilog}=globalThis.__udsVpnEnv;\n' +
          vpnSource,
        { mode: 'strip' }
      )
    ).toString('base64')
);

function resetAll() {
  fakeNow = 1_700_000_000_000;
  uuidSeq = 1;
  files.clear();
  intervals.clear();
  timeouts.clear();
  ctrlEnv = {
    onControl: () => '{"ok":true,"message":"ok"}',
    onUdsRequest: () => { throw new Error('uds unavailable'); }
  };
  vpnEnv = {
    vpn: false,
    core: false,
    startCalls: 0,
    stopCalls: 0,
    controls: [],
    udsListenCalls: [],
    udsCloseCalls: [],
    acceptCalls: [],
    incomingUds: [],
    udsReplies: [],
    openServerFds: new Set(),
    nextServerFd: 100,
    udsListenFail: false,
    udsListenThrows: false
  };
}

test('Control: UDS fast path succeeds without touching control-request.json', async () => {
  resetAll();
  const seen = [];
  ctrlEnv.onUdsRequest = (socketPath, payload, timeoutMs) => {
    const req = JSON.parse(payload);
    seen.push({ socketPath, req, timeoutMs });
    return JSON.stringify({ id: req.id, ok: true, message: 'switched via uds' });
  };

  const reply = await Control.sendControlResult('/test', 'select', 'Proxy', 'HK-01');
  assert.equal(reply.ok, true);
  assert.equal(reply.message, 'switched via uds');
  assert.equal(seen.length, 1);
  assert.equal(seen[0].socketPath, '/test/control.sock');
  assert.equal(seen[0].timeoutMs, 3000);
  assert.equal(seen[0].req.action, 'select');
  assert.equal(seen[0].req.group, 'Proxy');
  assert.equal(seen[0].req.outbound, 'HK-01');
  assert.equal(files.has('/test/control-request.json'), false, 'UDS fast path must not write file IPC');
});

test('Control: UDS ok=false error rejects directly without file IPC fallback', async () => {
  resetAll();
  ctrlEnv.onUdsRequest = (_socketPath, payload) => {
    const req = JSON.parse(payload);
    return JSON.stringify({ id: req.id, ok: false, message: 'group not found' });
  };

  await assert.rejects(
    () => Control.sendControlResult('/test', 'select', 'Missing', 'HK-01'),
    /group not found/
  );
  assert.equal(files.has('/test/control-request.json'), false, 'logical error over UDS must not fall back to file IPC');
});

test('Control: UDS failure transparently falls back to file IPC', async () => {
  resetAll();
  let udsAttempts = 0;
  ctrlEnv.onUdsRequest = () => {
    udsAttempts++;
    throw new Error('ENOENT: control.sock');
  };

  const pending = Control.sendControlResult('/test', 'mode', '', '', '', 'global');
  await Promise.resolve();
  assert.equal(udsAttempts, 1);
  assert.equal(files.has('/test/control-request.json'), true, 'fallback should write control-request.json');
  const req = JSON.parse(files.get('/test/control-request.json'));
  assert.equal(req.action, 'mode');
  assert.equal(req.mode, 'global');

  files.set('/test/control-result.json', JSON.stringify({ id: req.id, ok: true, message: 'mode updated via file' }));
  flushTimeouts(100);
  const reply = await pending;
  assert.equal(reply.ok, true);
  assert.equal(reply.message, 'mode updated via file');
});

test('Control: runDeepProbe, convertProfileText, and DashboardData.tunnels defaults', async () => {
  resetAll();
  assert.deepEqual(Control.emptyDashboard().tunnels, []);
  files.set('/test/dashboard.json', JSON.stringify({ groups: [], connections: [], logs: [], modes: [], mode: 'rule', wireGuard: [] }));
  assert.deepEqual(Control.readDashboard('/test').tunnels, []);

  ctrlEnv.onUdsRequest = (_socketPath, payload) => {
    const req = JSON.parse(payload);
    assert.equal(req.action, 'deep-probe');
    return JSON.stringify({
      id: req.id,
      ok: true,
      message: 'ok',
      deepProbe: {
        directIp: '1.2.3.4',
        directLatencyMs: 15,
        proxyIp: '5.6.7.8',
        proxyLatencyMs: 42,
        natType: 'Port Restricted',
        stunMapped: '5.6.7.8:55123',
        summary: '直连 15ms / 代理 42ms'
      }
    });
  };
  const probe = await Control.runDeepProbe('/test');
  assert.equal(probe.directIp, '1.2.3.4');
  assert.equal(probe.directLatencyMs, 15);
  assert.equal(probe.proxyIp, '5.6.7.8');
  assert.equal(probe.proxyLatencyMs, 42);
  assert.equal(probe.natType, 'Port Restricted');
  assert.equal(probe.stunMapped, '5.6.7.8:55123');
  assert.equal(probe.summary, '直连 15ms / 代理 42ms');

  const controlCalls = [];
  ctrlEnv.onControl = (req) => {
    controlCalls.push(req);
    if (req.content === 'bad') {
      return JSON.stringify({ ok: false, message: 'unsupported format' });
    }
    return JSON.stringify({ ok: true, message: 'converted', converted: '{"outbounds":[]}' });
  };
  const converted = await Control.convertProfileText('proxies:\n  - name: hk');
  assert.equal(converted, '{"outbounds":[]}');
  assert.deepEqual(controlCalls[0], { action: 'convert-profile', content: 'proxies:\n  - name: hk' });
  await assert.rejects(() => Control.convertProfileText('bad'), /unsupported format/);
});

test('SingboxVpnAbility: UDS server listen, accept/respond, adaptive timer, and cleanup', async () => {
  resetAll();
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  assert.equal(ability.status.phase, 'running');
  assert.deepEqual(vpnEnv.udsListenCalls, ['/test/control.sock']);
  // Background UDS timer should be 600ms
  const bgUdsTimer = [...intervals].find((t) => t.ms === 600);
  assert.ok(bgUdsTimer, 'expected 600ms UDS poll timer in background');

  // Enqueue ping + deep-probe + diagnose-host + invalid UDS requests
  vpnEnv.incomingUds.push(
    { fd: 201, payload: JSON.stringify({ id: 'u-ping', createdAt: fakeNow, action: 'ping' }) },
    { fd: 202, payload: JSON.stringify({ id: 'u-probe', createdAt: fakeNow, action: 'deep-probe' }) },
    { fd: 203, payload: JSON.stringify({ id: 'u-diag', createdAt: fakeNow, action: 'diagnose-host', host: 'example.com' }) },
    { fd: 204, payload: '{not-valid-json' }
  );

  // Trigger UDS timer callback
  bgUdsTimer.cb();
  await ability.task;

  assert.equal(vpnEnv.udsReplies.length, 4);
  assert.deepEqual(vpnEnv.udsReplies[0], { fd: 201, payload: { id: 'u-ping', ok: true, message: 'ok' } });
  assert.equal(vpnEnv.udsReplies[1].fd, 202);
  assert.equal(vpnEnv.udsReplies[1].payload.ok, true);
  assert.equal(vpnEnv.udsReplies[1].payload.deepProbe.natType, 'Full Cone');
  assert.equal(vpnEnv.udsReplies[1].payload.deepProbe.proxyIp, '198.51.100.22');
  assert.equal(vpnEnv.udsReplies[2].fd, 203);
  assert.equal(vpnEnv.udsReplies[2].payload.diagnosis.host, 'example.com');
  assert.equal(vpnEnv.udsReplies[3].fd, 204);
  assert.equal(vpnEnv.udsReplies[3].payload.ok, false);

  // UI becomes active -> syncUdsTimer switches UDS timer to 120ms
  files.set('/test/ui-demand.json', JSON.stringify({ updatedAt: fakeNow }));
  ability.tick();
  await ability.task;
  assert.ok([...intervals].some((t) => t.ms === 120), 'expected 120ms UDS poll timer when UI is active');
  assert.equal([...intervals].some((t) => t.ms === 600), false, 'old 600ms UDS timer should be replaced');

  // Destroy cleans up server fd, unlinks control.sock, and clears all timers
  ability.onDestroy();
  await ability.task;
  assert.equal(vpnEnv.udsCloseCalls.length, 1);
  assert.deepEqual(vpnEnv.udsCloseCalls[0], { fd: 100, socketPath: '/test/control.sock' });
  assert.equal(intervals.size, 0, 'all timers including udsTimer must be cleared on destroy');
});

test('SingboxVpnAbility: UDS listen failure degrades gracefully without breaking VPN startup', async () => {
  resetAll();
  vpnEnv.udsListenThrows = true;
  const ability = new SingboxVpnAbility();
  ability.onCreate({});
  await ability.task;

  assert.equal(ability.status.phase, 'running');
  assert.equal([...intervals].some((t) => t.ms === 120 || t.ms === 600), false);

  ability.onDestroy();
  await ability.task;
  assert.equal(vpnEnv.udsCloseCalls.length, 0);
  assert.equal(intervals.size, 0);
});

test('Native bridge contract: bridge.cpp and Index.d.ts expose all 5 UDS N-API methods with 0600 perms and 1 MiB cap', () => {
  const cpp = fs.readFileSync(new URL('../entry/src/main/cpp/bridge.cpp', import.meta.url), 'utf8');
  const dts = fs.readFileSync(new URL('../entry/src/main/cpp/types/libsingboxbridge/Index.d.ts', import.meta.url), 'utf8');
  for (const name of ['udsListen', 'udsAcceptRead', 'udsWriteClose', 'udsClose', 'udsRequest']) {
    assert.ok(cpp.includes(`"${name}"`), `bridge.cpp missing N-API export ${name}`);
    assert.ok(dts.includes(`export const ${name}:`), `Index.d.ts missing declaration ${name}`);
  }
  assert.ok(cpp.includes('AF_UNIX'), 'bridge.cpp must use AF_UNIX');
  assert.ok(cpp.includes('0600'), 'bridge.cpp must enforce 0600 socket permissions');
  assert.ok(cpp.includes('1024*1024'), 'bridge.cpp must enforce 1 MiB payload cap');
});

test.after(() => {
  Date.now = originalDateNow;
  globalThis.setInterval = originalSetInterval;
  globalThis.clearInterval = originalClearInterval;
  globalThis.setTimeout = originalSetTimeout;
  globalThis.clearTimeout = originalClearTimeout;
  delete globalThis.__udsCtrlEnv;
  delete globalThis.__udsWifiEnv;
  delete globalThis.__udsAoEnv;
  delete globalThis.__udsVpnEnv;
});
