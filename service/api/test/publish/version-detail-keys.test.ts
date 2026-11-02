import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { Harness, pkg } from './harness';

/**
 * What GET /packages/{name}/{version} serves is what spec/api/openapi.yaml's VersionDetail documents, and the spec documents
 * nothing the router does not serve but what is listed here. What it catches: a property written into the spec that no code
 * serves (the embedded `manifest` was one), and a key the router starts to serve that the spec does not describe.
 */
const SPEC = readFileSync(resolve(__dirname, '../../../../spec/api/openapi.yaml'), 'utf8');

/** The property names of a schema of components.schemas, read from the indented text. */
function schemaProperties(name: string): string[] {
  const lines = SPEC.split('\n');
  const at = lines.indexOf(`    ${name}:`);
  expect(at).toBeGreaterThan(0);
  const out: string[] = [];
  let inProps = false;
  for (const l of lines.slice(at + 1)) {
    if (/^ {0,4}\S/.test(l)) break; // the next schema
    if (/^ {6}properties:/.test(l)) inProps = true;
    else if (inProps && /^ {6}\S/.test(l)) inProps = false;
    const m = /^ {8}(\w+):/.exec(l);
    if (inProps && m) out.push(m[1]!);
  }
  return out;
}

/** In the spec and, by design, never served: the rendered readme (no code renders one) and the tombstone of a version that is not tombstoned. */
const NOT_SERVED_HERE = ['readme_html', 'tombstone'];

describe('getVersion against VersionDetail', () => {
  const documented = schemaProperties('VersionDetail');

  test('the scan reads the schema (a scan that finds nothing proves nothing)', () => {
    expect(documented).toEqual(expect.arrayContaining(['name', 'version', 'manifest_sha256', 'provenance', 'source_commit', 'group_id', 'readme']));
  });

  test('a published version with every optional field serves only documented keys, and every documented key but the two named', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    await h.publish(me.token, p, {
      description: 'd',
      license: 'MIT',
      repository: 'https://example.com/r',
      homepage: 'https://example.com',
      keywords: ['k'],
      readme: '# r',
      source_commit: 'c'.repeat(40),
    });
    await h.runValidator();
    await h.runIndexer();
    const body = JSON.parse((await h.call('GET', '/api/v1/packages/demo/1.0.0')).body) as Record<string, unknown>;
    const served = Object.keys(body);
    expect(served.filter((k) => !documented.includes(k))).toEqual([]);
    // group_id is served only for a group's version; the group tests pin it.
    expect(documented.filter((k) => !served.includes(k)).sort()).toEqual([...NOT_SERVED_HERE, 'group_id'].sort());
  });

  test('the embedded manifest is not served, and the spec does not promise it', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    await h.runIndexer();
    expect(JSON.parse((await h.call('GET', '/api/v1/packages/demo/1.0.0')).body)).not.toHaveProperty('manifest');
    expect(documented).not.toContain('manifest');
  });
});
