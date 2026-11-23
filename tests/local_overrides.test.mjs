import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bearbox-overrides-test-'));
let writeCalls = 0;

const writePrivate = (name, value) => {
  writeCalls++;
  const tmp = `${name}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(tmp, value, { mode: 0o600 });
  fs.renameSync(tmp, name);
};

globalThis.__overridesEnv = {
  readPrivate: (name) => fs.readFileSync(name, 'utf8'),
  writePrivate
};

const rawSource = fs
  .readFileSync(new URL('../entry/src/main/ets/common/LocalOverrides.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '');
const source = 'const {readPrivate, writePrivate} = globalThis.__overridesEnv;\n' + rawSource;
const api = await import(
  'data:text/javascript;base64,' +
    Buffer.from(stripTypeScriptTypes(source, { mode: 'strip' })).toString('base64')
);

test.after(() => {
  fs.rmSync(root, { recursive: true, force: true });
  delete globalThis.__overridesEnv;
});

test('defaultLocalOverrides returns disabled empty schema', () => {
  assert.deepEqual(api.defaultLocalOverrides(), {
    enabled: false,
    hosts: [],
    directDomains: [],
    proxyDomains: [],
    rejectDomains: [],
    directCidrs: [],
    proxyCidrs: [],
    rejectCidrs: []
  });
});

test('parseDomainList normalizes, deduplicates, validates and enforces limit', () => {
  const parsed = api.parseDomainList(' Example.COM , sub-1.test.org\r\nexample.com\n\nLOCALHOST ');
  assert.deepEqual(parsed, ['example.com', 'sub-1.test.org', 'localhost']);

  for (const bad of ['http://example.com', 'bad domain.com', '-bad.com', 'bad-.com', 'a..b.com', '.leading.com', 'trailing.com.', 'a'.repeat(64) + '.com']) {
    assert.throws(() => api.parseDomainList(bad), `expected invalid domain to throw: ${bad}`);
  }

  const max512 = Array.from({ length: 512 }, (_, i) => `d${i}.example.com`).join('\n');
  assert.equal(api.parseDomainList(max512).length, 512);
  const over512 = Array.from({ length: 513 }, (_, i) => `d${i}.example.com`).join(',');
  assert.throws(() => api.parseDomainList(over512));
});

test('parseCidrList validates IPv4/IPv6 CIDRs, deduplicates and enforces limit', () => {
  const parsed = api.parseCidrList('192.168.1.0/24, 10.0.0.0/8\n192.168.1.0/24\n2001:DB8::/32\n::/0\n::ffff:192.0.2.0/120');
  assert.deepEqual(parsed, [
    '192.168.1.0/24',
    '10.0.0.0/8',
    '2001:db8::/32',
    '::/0',
    '::ffff:192.0.2.0/120'
  ]);

  for (const bad of ['192.168.1.1', '192.168.1.0/33', '256.0.0.1/24', '01.2.3.4/24', '2001:db8::/129', '2001::db8::/32', 'not-a-cidr/24']) {
    assert.throws(() => api.parseCidrList(bad), `expected invalid CIDR to throw: ${bad}`);
  }

  const max512 = Array.from({ length: 512 }, (_, i) => `10.${Math.floor(i / 256)}.${i % 256}.0/24`).join('\n');
  assert.equal(api.parseCidrList(max512).length, 512);
  const over512 = Array.from({ length: 513 }, (_, i) => `10.${Math.floor(i / 256)}.${i % 256}.0/24`).join('\n');
  assert.throws(() => api.parseCidrList(over512));
});

test('parseHostLines and formatHostLines handle both syntaxes, dedupe and limits', () => {
  const parsed = api.parseHostLines([
    'Example.COM = 1.1.1.1, 2606:4700:4700::1111',
    'internal.lan 192.168.1.10',
    'example.com = 1.1.1.1, 1.0.0.1'
  ].join('\n'));
  assert.deepEqual(parsed, [
    { domain: 'example.com', ips: ['1.1.1.1', '2606:4700:4700::1111', '1.0.0.1'] },
    { domain: 'internal.lan', ips: ['192.168.1.10'] }
  ]);
  assert.equal(
    api.formatHostLines(parsed),
    'example.com = 1.1.1.1, 2606:4700:4700::1111, 1.0.0.1\ninternal.lan = 192.168.1.10'
  );

  for (const bad of ['example.com =', 'example.com', 'bad host = 1.1.1.1', 'example.com = 999.1.1.1', 'example.com = 1.1.1.1/24']) {
    assert.throws(() => api.parseHostLines(bad), `expected invalid host line to throw: ${bad}`);
  }

  const max256 = Array.from({ length: 256 }, (_, i) => `h${i}.lan 10.0.0.${i % 256}`).join('\n');
  assert.equal(api.parseHostLines(max256).length, 256);
  const over256 = Array.from({ length: 257 }, (_, i) => `h${i}.lan 10.0.0.${i % 256}`).join('\n');
  assert.throws(() => api.parseHostLines(over256));
});

test('loadLocalOverrides safely falls back on missing or corrupt files and saveLocalOverrides writes 0600 atomically', () => {
  assert.deepEqual(api.loadLocalOverrides(root), api.defaultLocalOverrides());

  const filePath = path.join(root, 'overrides.json');
  fs.writeFileSync(filePath, '{corrupt json');
  assert.deepEqual(api.loadLocalOverrides(root), api.defaultLocalOverrides());

  fs.writeFileSync(filePath, '["not-an-object"]');
  assert.deepEqual(api.loadLocalOverrides(root), api.defaultLocalOverrides());

  const valid = {
    enabled: true,
    hosts: [{ domain: 'Api.Local', ips: ['127.0.0.1', '::1'] }],
    directDomains: ['Example.COM'],
    proxyDomains: ['blocked.org'],
    rejectDomains: ['ads.example.net'],
    directCidrs: ['192.168.0.0/16'],
    proxyCidrs: ['2001:DB8::/32'],
    rejectCidrs: ['198.51.100.0/24']
  };
  const beforeWrites = writeCalls;
  api.saveLocalOverrides(root, valid);
  assert.equal(writeCalls, beforeWrites + 1);

  const stat = fs.statSync(filePath);
  assert.equal(stat.mode & 0o777, 0o600);
  assert.deepEqual(api.loadLocalOverrides(root), {
    enabled: true,
    hosts: [{ domain: 'api.local', ips: ['127.0.0.1', '::1'] }],
    directDomains: ['example.com'],
    proxyDomains: ['blocked.org'],
    rejectDomains: ['ads.example.net'],
    directCidrs: ['192.168.0.0/16'],
    proxyCidrs: ['2001:db8::/32'],
    rejectCidrs: ['198.51.100.0/24']
  });

  // Invalid save must throw and leave previous valid file intact
  assert.throws(() =>
    api.saveLocalOverrides(root, {
      ...valid,
      directCidrs: ['invalid-cidr']
    })
  );
  assert.equal(api.loadLocalOverrides(root).enabled, true);
  assert.deepEqual(api.loadLocalOverrides(root).directCidrs, ['192.168.0.0/16']);
});
