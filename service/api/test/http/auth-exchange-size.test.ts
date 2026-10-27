import { route, type HttpRequest, type RouterDeps } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import type { AuthServices } from '../../src/http/auth-routes';

// The size of the CI exchange's request body, through the router. What this proves: a set of the most packages a group may hold
// (500), each with the longest name and version, fits the body cap of the exchange; a body past that cap is refused as too large;
// and the other auth routes keep their smaller cap. What it does not: the identity token's verification (the exchange is a stub).

const entry = (i: number) => ({ name: `p${String(i).padStart(3, '0')}${'a'.repeat(60)}`, version: `1.0.${'9'.repeat(124)}` });

function send(path: string, raw: string, onExchange: (input: { packages: unknown[] }) => void) {
  const auth = {
    devices: async () => ({ start: async () => ({}) }),
    oidc: {
      exchange: async (input: { packages: unknown[] }) => {
        onExchange(input);
        return { token_kind: 'publish', packages: input.packages };
      },
    },
  } as unknown as AuthServices;
  const deps: RouterDeps = { store: new MemoryStore(), stage: 'beta', version: 'v', commit: 'c', readOnly: false, auth };
  const req: HttpRequest = { method: 'POST', path: `/api/v1${path}`, query: {}, headers: {}, body: raw };
  return route(req, deps, 'req-size');
}

describe('the body of the CI exchange', () => {
  test('500 packages of the longest name and version are accepted', async () => {
    const packages = Array.from({ length: 500 }, (_x, i) => entry(i));
    expect(packages[0]!.name).toHaveLength(64);
    expect(packages[0]!.version).toHaveLength(128);
    const raw = JSON.stringify({ jwt: `${'a'.repeat(1500)}.${'b'.repeat(1500)}.${'c'.repeat(342)}`, packages });
    expect(raw.length).toBeGreaterThan(64 * 1024);
    let seen = 0;
    const res = await send('/auth/oidc/exchange', raw, (i) => (seen = i.packages.length));
    expect(res.statusCode).toBe(200);
    expect(seen).toBe(500);
  });

  test('a body past the exchange cap is too large, and another auth route is still capped at 64 KiB', async () => {
    const big = JSON.stringify({ jwt: 'x', pad: 'y'.repeat(128 * 1024) });
    let called = false;
    const res = await send('/auth/oidc/exchange', big, () => (called = true));
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body!).error.message).toContain('the body is too large');
    expect(called).toBe(false);
    const mid = JSON.stringify({ client: 'z'.repeat(70_000) });
    const other = await send('/auth/device', mid, () => undefined);
    expect(other.statusCode).toBe(400);
    expect(JSON.parse(other.body!).error.message).toContain('the body is too large');
  });
});
