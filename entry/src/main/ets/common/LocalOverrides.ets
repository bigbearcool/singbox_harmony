import { readPrivate, writePrivate } from './Store';

export interface HostOverride {
  domain: string;
  ips: string[];
}

export interface LocalOverrides {
  enabled: boolean;
  hosts: HostOverride[];
  directDomains: string[];
  proxyDomains: string[];
  rejectDomains: string[];
  directCidrs: string[];
  proxyCidrs: string[];
  rejectCidrs: string[];
}

const MAX_DOMAINS: number = 512;
const MAX_CIDRS: number = 512;
const MAX_HOSTS: number = 256;

const DOMAIN_LABEL_RE: RegExp = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const IPV4_OCTET_RE: RegExp = /^(?:0|[1-9][0-9]{0,2})$/;
const IPV6_GROUP_RE: RegExp = /^[0-9a-fA-F]{1,4}$/;
const PREFIX_RE: RegExp = /^(?:0|[1-9][0-9]{0,2})$/;

export function defaultLocalOverrides(): LocalOverrides {
  return {
    enabled: false,
    hosts: [],
    directDomains: [],
    proxyDomains: [],
    rejectDomains: [],
    directCidrs: [],
    proxyCidrs: [],
    rejectCidrs: []
  };
}

function isValidDomain(domain: string): boolean {
  if (domain.length === 0 || domain.length > 253) {
    return false;
  }
  const labels: string[] = domain.split('.');
  for (const label of labels) {
    if (!DOMAIN_LABEL_RE.test(label)) {
      return false;
    }
  }
  return true;
}

function isValidIPv4(ip: string): boolean {
  const parts: string[] = ip.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    if (!IPV4_OCTET_RE.test(part)) {
      return false;
    }
    const value: number = Number(part);
    if (value < 0 || value > 255) {
      return false;
    }
  }
  return true;
}

function isValidIPv6(ip: string): boolean {
  if (ip.length === 0 || ip.length > 45 || !ip.includes(':')) {
    return false;
  }
  const halves: string[] = ip.split('::');
  if (halves.length > 2) {
    return false;
  }
  if (halves.length === 2) {
    const left: string[] = halves[0] === '' ? [] : halves[0].split(':');
    const right: string[] = halves[1] === '' ? [] : halves[1].split(':');
    let count: number = 0;
    for (const group of left) {
      if (!IPV6_GROUP_RE.test(group)) {
        return false;
      }
      count++;
    }
    for (let i: number = 0; i < right.length; i++) {
      const group: string = right[i];
      if (i === right.length - 1 && group.includes('.')) {
        if (!isValidIPv4(group)) {
          return false;
        }
        count += 2;
      } else {
        if (!IPV6_GROUP_RE.test(group)) {
          return false;
        }
        count++;
      }
    }
    return count <= 7;
  }
  const groups: string[] = ip.split(':');
  if (groups.length === 7 && groups[6].includes('.')) {
    for (let i: number = 0; i < 6; i++) {
      if (!IPV6_GROUP_RE.test(groups[i])) {
        return false;
      }
    }
    return isValidIPv4(groups[6]);
  }
  if (groups.length !== 8) {
    return false;
  }
  for (const group of groups) {
    if (!IPV6_GROUP_RE.test(group)) {
      return false;
    }
  }
  return true;
}

function isValidIP(ip: string): boolean {
  return isValidIPv4(ip) || isValidIPv6(ip);
}

function isValidCidr(cidr: string): boolean {
  const parts: string[] = cidr.split('/');
  if (parts.length !== 2) {
    return false;
  }
  const addr: string = parts[0];
  const prefixText: string = parts[1];
  if (!PREFIX_RE.test(prefixText)) {
    return false;
  }
  const prefix: number = Number(prefixText);
  if (isValidIPv4(addr)) {
    return prefix >= 0 && prefix <= 32;
  }
  if (isValidIPv6(addr)) {
    return prefix >= 0 && prefix <= 128;
  }
  return false;
}

export function parseDomainList(text: string): string[] {
  const result: string[] = [];
  for (const raw of text.split(/[\r\n,]+/)) {
    const domain: string = raw.trim().toLowerCase();
    if (domain.length === 0) {
      continue;
    }
    if (!isValidDomain(domain)) {
      throw new Error(`无效域名: ${raw.trim()}`);
    }
    if (!result.includes(domain)) {
      result.push(domain);
      if (result.length > MAX_DOMAINS) {
        throw new Error(`最多保存 ${MAX_DOMAINS} 条域名规则`);
      }
    }
  }
  return result;
}

export function parseCidrList(text: string): string[] {
  const result: string[] = [];
  for (const raw of text.split(/[\r\n,]+/)) {
    const cidr: string = raw.trim().toLowerCase();
    if (cidr.length === 0) {
      continue;
    }
    if (!isValidCidr(cidr)) {
      throw new Error(`无效 CIDR: ${raw.trim()}`);
    }
    if (!result.includes(cidr)) {
      result.push(cidr);
      if (result.length > MAX_CIDRS) {
        throw new Error(`最多保存 ${MAX_CIDRS} 条 CIDR 规则`);
      }
    }
  }
  return result;
}

export function parseHostLines(text: string): HostOverride[] {
  const result: HostOverride[] = [];
  const indexByDomain: Map<string, number> = new Map<string, number>();
  for (const rawLine of text.split(/\r?\n/)) {
    const line: string = rawLine.trim();
    if (line.length === 0) {
      continue;
    }
    let domain: string = '';
    let ipTokens: string[] = [];
    const eqIndex: number = line.indexOf('=');
    if (eqIndex !== -1) {
      domain = line.slice(0, eqIndex).trim().toLowerCase();
      const rhs: string = line.slice(eqIndex + 1).trim();
      ipTokens = rhs.length === 0 ? [] : rhs.split(/[\s,]+/);
    } else {
      const parts: string[] = line.split(/\s+/);
      domain = parts[0].trim().toLowerCase();
      const rest: string = parts.slice(1).join(' ');
      ipTokens = rest.length === 0 ? [] : rest.split(/[\s,]+/);
    }
    if (!isValidDomain(domain)) {
      throw new Error(`无效 Hosts 域名: ${line}`);
    }
    const validIps: string[] = [];
    for (const token of ipTokens) {
      const ip: string = token.trim().toLowerCase();
      if (ip.length === 0) {
        continue;
      }
      if (!isValidIP(ip)) {
        throw new Error(`无效 Hosts IP: ${token}`);
      }
      if (!validIps.includes(ip)) {
        validIps.push(ip);
      }
    }
    if (validIps.length === 0) {
      throw new Error(`Hosts 规则缺少有效 IP: ${line}`);
    }
    const existingIndex: number | undefined = indexByDomain.get(domain);
    if (existingIndex !== undefined) {
      const existing: HostOverride = result[existingIndex];
      for (const ip of validIps) {
        if (!existing.ips.includes(ip)) {
          existing.ips.push(ip);
        }
      }
    } else {
      if (result.length >= MAX_HOSTS) {
        throw new Error(`最多保存 ${MAX_HOSTS} 条 Hosts 规则`);
      }
      indexByDomain.set(domain, result.length);
      result.push({ domain: domain, ips: validIps });
    }
  }
  return result;
}

export function formatHostLines(hosts: HostOverride[]): string {
  return hosts.map((item: HostOverride): string => `${item.domain} = ${item.ips.join(', ')}`).join('\n');
}

function validateDomainArray(items: string[], label: string): string[] {
  if (!Array.isArray(items)) {
    throw new Error(`${label} 必须是数组`);
  }
  const result: string[] = [];
  for (const item of items) {
    if (typeof item !== 'string') {
      throw new Error(`${label} 包含无效项`);
    }
    const domain: string = item.trim().toLowerCase();
    if (!isValidDomain(domain)) {
      throw new Error(`${label} 包含无效域名: ${item}`);
    }
    if (!result.includes(domain)) {
      result.push(domain);
      if (result.length > MAX_DOMAINS) {
        throw new Error(`最多保存 ${MAX_DOMAINS} 条域名规则`);
      }
    }
  }
  return result;
}

function validateCidrArray(items: string[], label: string): string[] {
  if (!Array.isArray(items)) {
    throw new Error(`${label} 必须是数组`);
  }
  const result: string[] = [];
  for (const item of items) {
    if (typeof item !== 'string') {
      throw new Error(`${label} 包含无效项`);
    }
    const cidr: string = item.trim().toLowerCase();
    if (!isValidCidr(cidr)) {
      throw new Error(`${label} 包含无效 CIDR: ${item}`);
    }
    if (!result.includes(cidr)) {
      result.push(cidr);
      if (result.length > MAX_CIDRS) {
        throw new Error(`最多保存 ${MAX_CIDRS} 条 CIDR 规则`);
      }
    }
  }
  return result;
}

function validateHostArray(items: HostOverride[]): HostOverride[] {
  if (!Array.isArray(items)) {
    throw new Error('hosts 必须是数组');
  }
  const result: HostOverride[] = [];
  const indexByDomain: Map<string, number> = new Map<string, number>();
  for (const item of items) {
    if (!item || typeof item.domain !== 'string' || !Array.isArray(item.ips)) {
      throw new Error('hosts 规则格式无效');
    }
    const domain: string = item.domain.trim().toLowerCase();
    if (!isValidDomain(domain)) {
      throw new Error(`hosts 包含无效域名: ${item.domain}`);
    }
    const ips: string[] = [];
    for (const rawIp of item.ips) {
      if (typeof rawIp !== 'string') {
        throw new Error('hosts IP 必须是字符串');
      }
      const ip: string = rawIp.trim().toLowerCase();
      if (!isValidIP(ip)) {
        throw new Error(`hosts 包含无效 IP: ${rawIp}`);
      }
      if (!ips.includes(ip)) {
        ips.push(ip);
      }
    }
    if (ips.length === 0) {
      throw new Error(`hosts 规则缺少有效 IP: ${domain}`);
    }
    const existingIndex: number | undefined = indexByDomain.get(domain);
    if (existingIndex !== undefined) {
      const existing: HostOverride = result[existingIndex];
      for (const ip of ips) {
        if (!existing.ips.includes(ip)) {
          existing.ips.push(ip);
        }
      }
    } else {
      if (result.length >= MAX_HOSTS) {
        throw new Error(`最多保存 ${MAX_HOSTS} 条 Hosts 规则`);
      }
      indexByDomain.set(domain, result.length);
      result.push({ domain: domain, ips: ips });
    }
  }
  return result;
}

export function loadLocalOverrides(dir: string): LocalOverrides {
  try {
    const raw: string = readPrivate(`${dir}/overrides.json`);
    const parsed: LocalOverrides = JSON.parse(raw) as LocalOverrides;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return defaultLocalOverrides();
    }
    return {
      enabled: parsed.enabled === true,
      hosts: parsed.hosts !== undefined ? validateHostArray(parsed.hosts) : [],
      directDomains: parsed.directDomains !== undefined ? validateDomainArray(parsed.directDomains, 'directDomains') : [],
      proxyDomains: parsed.proxyDomains !== undefined ? validateDomainArray(parsed.proxyDomains, 'proxyDomains') : [],
      rejectDomains: parsed.rejectDomains !== undefined ? validateDomainArray(parsed.rejectDomains, 'rejectDomains') : [],
      directCidrs: parsed.directCidrs !== undefined ? validateCidrArray(parsed.directCidrs, 'directCidrs') : [],
      proxyCidrs: parsed.proxyCidrs !== undefined ? validateCidrArray(parsed.proxyCidrs, 'proxyCidrs') : [],
      rejectCidrs: parsed.rejectCidrs !== undefined ? validateCidrArray(parsed.rejectCidrs, 'rejectCidrs') : []
    };
  } catch (_error) {
    return defaultLocalOverrides();
  }
}

export function saveLocalOverrides(dir: string, value: LocalOverrides): void {
  const normalized: LocalOverrides = {
    enabled: value.enabled === true,
    hosts: validateHostArray(value.hosts),
    directDomains: validateDomainArray(value.directDomains, 'directDomains'),
    proxyDomains: validateDomainArray(value.proxyDomains, 'proxyDomains'),
    rejectDomains: validateDomainArray(value.rejectDomains, 'rejectDomains'),
    directCidrs: validateCidrArray(value.directCidrs, 'directCidrs'),
    proxyCidrs: validateCidrArray(value.proxyCidrs, 'proxyCidrs'),
    rejectCidrs: validateCidrArray(value.rejectCidrs, 'rejectCidrs')
  };
  writePrivate(`${dir}/overrides.json`, JSON.stringify(normalized));
}
