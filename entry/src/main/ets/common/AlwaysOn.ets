import { readPrivate, writePrivate } from './Store';

export type DesiredVpnMode = 'connected' | 'stopped';
export type SelfHealAction = 'none' | 'reset' | 'rebuild';

export interface DesiredVpnState {
  desired: DesiredVpnMode;
  updatedAt: number;
  lastInterruptionAt?: number;
  lastInterruptionReason?: string;
  lastHandoverAt?: number;
  handoverCount?: number;
  selfHealCount?: number;
}

const DESIRED_STATE_FILE: string = 'desired-state.json';

export function defaultDesiredState(): DesiredVpnState {
  return {
    desired: 'stopped',
    updatedAt: 0,
    handoverCount: 0,
    selfHealCount: 0
  };
}

export function loadDesiredState(dir: string): DesiredVpnState {
  try {
    const raw: DesiredVpnState = JSON.parse(readPrivate(`${dir}/${DESIRED_STATE_FILE}`)) as DesiredVpnState;
    if (!raw || typeof raw !== 'object') {
      return defaultDesiredState();
    }
    const state: DesiredVpnState = {
      desired: raw.desired === 'connected' ? 'connected' : 'stopped',
      updatedAt: typeof raw.updatedAt === 'number' && Number.isFinite(raw.updatedAt) ? raw.updatedAt : 0
    };
    if (typeof raw.lastInterruptionAt === 'number' && Number.isFinite(raw.lastInterruptionAt)) {
      state.lastInterruptionAt = raw.lastInterruptionAt;
    }
    if (typeof raw.lastInterruptionReason === 'string' && raw.lastInterruptionReason.length > 0) {
      state.lastInterruptionReason = raw.lastInterruptionReason;
    }
    if (typeof raw.lastHandoverAt === 'number' && Number.isFinite(raw.lastHandoverAt)) {
      state.lastHandoverAt = raw.lastHandoverAt;
    }
    if (typeof raw.handoverCount === 'number' && Number.isFinite(raw.handoverCount) && raw.handoverCount >= 0) {
      state.handoverCount = raw.handoverCount;
    } else {
      state.handoverCount = 0;
    }
    if (typeof raw.selfHealCount === 'number' && Number.isFinite(raw.selfHealCount) && raw.selfHealCount >= 0) {
      state.selfHealCount = raw.selfHealCount;
    } else {
      state.selfHealCount = 0;
    }
    return state;
  } catch (_error) {
    return defaultDesiredState();
  }
}

export function saveDesiredState(dir: string, state: DesiredVpnState): void {
  try {
    writePrivate(`${dir}/${DESIRED_STATE_FILE}`, JSON.stringify(state));
  } catch (_error) {}
}

export function recordInterruption(dir: string, reason: string): void {
  const current: DesiredVpnState = loadDesiredState(dir);
  if (current.desired !== 'connected') {
    return;
  }
  const now: number = Date.now();
  const next: DesiredVpnState = {
    desired: current.desired,
    updatedAt: now,
    lastInterruptionAt: now,
    lastInterruptionReason: reason,
    lastHandoverAt: current.lastHandoverAt,
    handoverCount: current.handoverCount || 0,
    selfHealCount: current.selfHealCount || 0
  };
  saveDesiredState(dir, next);
}

export function recordHandover(dir: string): number {
  const current: DesiredVpnState = loadDesiredState(dir);
  const now: number = Date.now();
  const count: number = (current.handoverCount || 0) + 1;
  const next: DesiredVpnState = {
    desired: current.desired,
    updatedAt: now,
    lastInterruptionAt: current.lastInterruptionAt,
    lastInterruptionReason: current.lastInterruptionReason,
    lastHandoverAt: now,
    handoverCount: count,
    selfHealCount: current.selfHealCount || 0
  };
  saveDesiredState(dir, next);
  return count;
}

export function recordSelfHeal(dir: string): number {
  const current: DesiredVpnState = loadDesiredState(dir);
  const now: number = Date.now();
  const count: number = (current.selfHealCount || 0) + 1;
  const next: DesiredVpnState = {
    desired: current.desired,
    updatedAt: now,
    lastInterruptionAt: current.lastInterruptionAt,
    lastInterruptionReason: current.lastInterruptionReason,
    lastHandoverAt: current.lastHandoverAt,
    handoverCount: current.handoverCount || 0,
    selfHealCount: count
  };
  saveDesiredState(dir, next);
  return count;
}

export class ClockJumpDetector {
  private lastObservedAt: number = 0;

  observe(nowMs: number, expectedIntervalMs: number): boolean {
    if (this.lastObservedAt <= 0) {
      this.lastObservedAt = nowMs;
      return false;
    }
    const delta: number = nowMs - this.lastObservedAt;
    this.lastObservedAt = nowMs;
    const threshold: number = Math.max(expectedIntervalMs * 3, 90000);
    return delta > threshold;
  }

  reset(nowMs: number = 0): void {
    this.lastObservedAt = nowMs;
  }
}

export class SelfHealTracker {
  private lastBindFailure: number = 0;
  private consecutiveFaults: number = 0;
  private consecutiveResets: number = 0;
  private readonly faultThreshold: number;
  private readonly rebuildThreshold: number;

  constructor(faultThreshold: number = 2, rebuildThreshold: number = 3) {
    this.faultThreshold = faultThreshold > 0 ? faultThreshold : 2;
    this.rebuildThreshold = rebuildThreshold > 0 ? rebuildThreshold : 3;
  }

  observe(bindFailure: number, dnsError: string): SelfHealAction {
    const safeBindFailure: number = bindFailure > 0 ? bindFailure : 0;
    const bindIncreased: boolean = safeBindFailure > this.lastBindFailure;
    this.lastBindFailure = safeBindFailure;
    const hasDnsError: boolean = dnsError.trim().length > 0;

    if (!bindIncreased && !hasDnsError) {
      this.consecutiveFaults = 0;
      this.consecutiveResets = 0;
      return 'none';
    }

    this.consecutiveFaults += 1;
    if (this.consecutiveFaults < this.faultThreshold) {
      return 'none';
    }

    this.consecutiveFaults = 0;
    this.consecutiveResets += 1;
    if (this.consecutiveResets >= this.rebuildThreshold) {
      this.consecutiveResets = 0;
      return 'rebuild';
    }
    return 'reset';
  }

  reset(): void {
    this.lastBindFailure = 0;
    this.consecutiveFaults = 0;
    this.consecutiveResets = 0;
  }
}

export class HandoverDebouncer {
  private timer: number = -1;
  private readonly delayMs: number;

  constructor(delayMs: number = 450) {
    this.delayMs = delayMs >= 0 ? delayMs : 450;
  }

  schedule(fn: () => void): void {
    this.cancel();
    this.timer = setTimeout((): void => {
      this.timer = -1;
      fn();
    }, this.delayMs) as number;
  }

  cancel(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  isPending(): boolean {
    return this.timer !== -1;
  }
}
