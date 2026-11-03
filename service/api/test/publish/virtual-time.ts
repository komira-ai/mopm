/**
 * Virtual time with real concurrency: a call sleeps for its charge, and the time moves on to the next sleeper only when nothing
 * else can run, so calls made at once take as long as one and calls one after the other add up. Nothing here reads the wall clock.
 */

/** What one charged call takes unless the test says otherwise, in milliseconds. */
export const CALL_MS = 20;

/** Virtual time: `sleep` is resolved in the order of its due times once every other promise has settled. */
export class VirtualTime {
  now = 0;
  private sleepers: Array<{ at: number; wake: () => void }> = [];
  private armed = false;
  constructor(private readonly moved: (now: number) => void) {}
  sleep(ms: number): Promise<void> {
    return new Promise((wake) => {
      this.sleepers.push({ at: this.now + ms, wake });
      this.arm();
    });
  }
  private arm() {
    if (this.armed) return;
    this.armed = true;
    setImmediate(() => {
      this.armed = false;
      if (this.sleepers.length === 0) return;
      const at = Math.min(...this.sleepers.map((s) => s.at));
      this.now = at;
      this.moved(at);
      const due = this.sleepers.filter((s) => s.at <= at);
      this.sleepers = this.sleepers.filter((s) => s.at > at);
      for (const s of due) s.wake();
      if (this.sleepers.length > 0) this.arm();
    });
  }
}

/** Make these methods of `target` take `ms` of virtual time each, and count the calls by method name. */
export function charged(target: object, methods: readonly string[], time: VirtualTime, calls: Map<string, number>, callMs = CALL_MS, dearer: Record<string, number> = {}) {
  const t = target as Record<string, (...a: unknown[]) => Promise<unknown>>;
  for (const m of methods) {
    const orig = t[m]!.bind(target);
    t[m] = async (...a) => {
      calls.set(m, (calls.get(m) ?? 0) + 1);
      await time.sleep(dearer[m] ?? callMs);
      return orig(...a);
    };
  }
}

