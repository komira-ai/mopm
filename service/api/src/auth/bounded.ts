/** How many names of one exchange are looked up or created at once (the group service's batch size). */
export const EXCHANGE_CONCURRENCY = 16;

/**
 * `fn` over `items` with at most `limit` calls in flight. Items are started in order and no new one is started once any call has
 * failed. If any failed, the error of the lowest index is thrown after every call already in flight has settled, which is the
 * error a loop in order would have thrown. Otherwise the results, in the order of `items`.
 */
export async function mapBounded<T, R>(items: readonly T[], limit: number, fn: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  const failures = new Map<number, unknown>();
  let next = 0;
  const worker = async () => {
    while (failures.size === 0 && next < items.length) {
      const i = next++;
      try {
        results[i] = await fn(items[i]!, i);
      } catch (err) {
        failures.set(i, err);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  if (failures.size > 0) throw failures.get(Math.min(...failures.keys()));
  return results;
}
