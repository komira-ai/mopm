import { mapBounded } from '../../src/auth/bounded';

// mapBounded runs a function over a list with a bound on the calls in flight. What these prove: the bound holds and is reached,
// the results keep the order of the list, and when several calls fail the error thrown is the one of the lowest index (the one a
// loop in order would have thrown), not the one that happened to fail first. Calls are held and released by hand, so no test
// depends on how long anything takes.

function deferred<T = void>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('mapBounded', () => {
  test('results are in the order of the items, and the calls in flight reach the bound and never pass it', async () => {
    let inFlight = 0;
    let max = 0;
    const out = await mapBounded(Array.from({ length: 50 }, (_x, i) => i), 7, async (n) => {
      inFlight++;
      max = Math.max(max, inFlight);
      await new Promise<void>((r) => setImmediate(r));
      inFlight--;
      return n * 2;
    });
    expect(out).toEqual(Array.from({ length: 50 }, (_x, i) => i * 2));
    expect(max).toBe(7);
  });

  test('an empty list is an empty result', async () => {
    expect(await mapBounded([], 16, async () => 1)).toEqual([]);
  });

  test('of two failures the lower index is thrown even when the higher index failed first', async () => {
    const slow = deferred();
    const seen: number[] = [];
    const run = mapBounded([0, 1, 2, 3], 4, async (n) => {
      seen.push(n);
      if (n === 0) {
        await slow.promise;
        throw new Error('index 0');
      }
      if (n === 2) {
        // Fails now, before index 0 does; index 0 is released only after this.
        queueMicrotask(() => slow.resolve());
        throw new Error('index 2');
      }
      return n;
    });
    await expect(run).rejects.toThrow('index 0');
    expect(seen).toEqual([0, 1, 2, 3]);
  });

  test('after a failure no new call is started, and the calls already running are awaited', async () => {
    const gate = deferred();
    let finished = false;
    const started: number[] = [];
    const run = mapBounded([0, 1, 2, 3, 4, 5], 2, async (n) => {
      started.push(n);
      if (n === 0) {
        await gate.promise;
        finished = true;
        return n;
      }
      if (n === 1) {
        queueMicrotask(() => gate.resolve());
        throw new Error('index 1');
      }
      return n;
    });
    await expect(run).rejects.toThrow('index 1');
    expect(finished).toBe(true);
    expect(started).toEqual([0, 1]);
  });
});
