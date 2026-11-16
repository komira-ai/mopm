import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { AuthError, NamespaceError } from '../../src/auth/errors';
import { RegistryError } from '../../src/errors';
import { errorViewV2, V2_CATALOGUE } from '../../src/http/v2-catalogue';
import { PublishError } from '../../src/publish/errors';

const SPEC = resolve(__dirname, '../../../../spec/api/openapi-v2.yaml');
const LINES = readFileSync(SPEC, 'utf8').split('\n');

/** The `x-mopm-errors` table of spec/api/openapi-v2.yaml: code -> status, message, hint. */
function specCatalogue(): Record<string, { status: number; message: string; hint: string }> {
  const out: Record<string, { status: number; message: string; hint: string }> = {};
  const line = /^ {2}(\w+):\s+\{ status: (\d+), message: ("(?:[^"\\]|\\.)*"), hint: ("(?:[^"\\]|\\.)*") \}\s*$/;
  let inTable = false;
  for (const l of LINES) {
    if (/^\S/.test(l)) inTable = l.startsWith('x-mopm-errors:');
    const m = inTable ? line.exec(l) : null;
    if (m) out[m[1]!] = { status: Number(m[2]), message: JSON.parse(m[3]!), hint: JSON.parse(m[4]!) };
  }
  return out;
}

/** The `ErrorCode` enum of the spec, in file order. */
function specErrorCodes(): string[] {
  const out: string[] = [];
  let inEnum = false;
  for (const l of LINES) {
    if (/^ {4}\w+:/.test(l)) inEnum = false;
    if (l === '    ErrorCode:') inEnum = true;
    const m = inEnum ? /^ {8}- (\w+)\s*$/.exec(l) : null;
    if (m) out.push(m[1]!);
  }
  return out;
}

describe('the /api/v2 error catalogue is the contract\'s', () => {
  const spec = specCatalogue();
  const enumCodes = specErrorCodes();

  test('both tables were found (the parsers read what the test thinks they read)', () => {
    expect(Object.keys(spec).length).toBeGreaterThan(38);
    expect(spec.name_reserved).toBeDefined();
    expect(spec.namespace_not_found).toBeDefined();
    expect(enumCodes.length).toBeGreaterThan(38);
  });

  test.each(Object.keys(V2_CATALOGUE))('%s: status, message and hint equal the spec text', (code) => {
    expect(spec[code]).toEqual(V2_CATALOGUE[code]);
  });

  test('the spec holds no code the service does not answer', () => {
    expect(Object.keys(spec).sort()).toEqual(Object.keys(V2_CATALOGUE).sort());
  });

  test('every catalogue code is in the ErrorCode enum, and the enum holds nothing else', () => {
    for (const code of Object.keys(V2_CATALOGUE)) expect(enumCodes).toContain(code);
    expect([...enumCodes].sort()).toEqual(Object.keys(V2_CATALOGUE).sort());
    expect(new Set(enumCodes).size).toBe(enumCodes.length);
  });

  test('name_reserved says what the name is, the codes of the namespaces carry their statuses', () => {
    expect(spec.name_reserved).toEqual({ status: 403, message: "'{name}' is {what}.", hint: 'Choose another name.' });
    const statuses: Record<string, number> = {
      invalid_namespace: 400,
      namespace_reserved: 403,
      namespace_not_found: 404,
      namespace_taken: 409,
      not_namespace_member: 403,
      not_namespace_owner: 403,
      not_org_admin: 403,
      github_account_mismatch: 403,
      last_owner: 409,
      member_not_found: 404,
      user_not_found: 404,
    };
    for (const [code, status] of Object.entries(statuses)) expect(spec[code]!.status).toBe(status);
  });

  test('the App-based namespace code is gone from the contract and from the service', () => {
    expect(spec.namespace_unverified).toBeUndefined();
    expect(V2_CATALOGUE.namespace_unverified).toBeUndefined();
  });

  test('codes of the retired owner model are not in the contract', () => {
    for (const code of ['owner_not_found', 'already_owner', 'invitation_not_found', 'invitation_expired']) {
      expect(spec[code]).toBeUndefined();
    }
  });
});

describe('errorViewV2', () => {
  test('renders name_reserved with the what of its detail, and with "reserved" when the error has none', () => {
    const std = errorViewV2(new RegistryError('name_reserved', 'x', { name: 'collections', what: 'a module of the Mojo standard library (std.collections)' }));
    expect(std.status).toBe(403);
    expect(std.body.error.message).toBe("'collections' is a module of the Mojo standard library (std.collections).");
    expect(errorViewV2(new RegistryError('name_reserved', 'x', { name: 'fn' })).body.error.message).toBe("'fn' is reserved.");
  });

  test('renders a namespace error, an auth error and a publish error from the catalogue', () => {
    expect(errorViewV2(new NamespaceError('namespace_not_found', 'x', { namespace: 'nobody' })).body.error).toEqual({
      code: 'namespace_not_found',
      message: "There is no namespace 'nobody'.",
      hint: "A user's namespace is made at their first 'mopm login'; an organization's by one of its admins.",
    });
    expect(errorViewV2(new AuthError('unavailable', 'x')).status).toBe(503);
    expect(errorViewV2(new PublishError('rate_limited', 'x', { retry_after: '60' }, 60)).retryAfter).toBe(60);
  });

  test('renders the member codes with the user and the namespace of their detail', () => {
    expect(errorViewV2(new NamespaceError('last_owner', 'x', { user: 'alice', namespace: 'komira-ai' }))).toMatchObject({
      status: 409,
      body: { error: { code: 'last_owner', message: "'alice' is the last owner of 'komira-ai'.", hint: 'Make another member an owner first.' } },
    });
    expect(errorViewV2(new NamespaceError('member_not_found', 'x', { user: 'bob', namespace: 'komira-ai' })).body.error.message).toBe("'bob' is not a member of 'komira-ai'.");
    expect(errorViewV2(new NamespaceError('user_not_found', 'x', { user: 'ghost' })).body.error.message).toBe("There is no mopm user 'ghost'.");
  });

  test('an error of no known class, or of a code the catalogue lacks, is internal_error', () => {
    expect(errorViewV2(new Error('boom')).body.error.code).toBe('internal_error');
    expect(errorViewV2(new RegistryError('owner_not_found', 'x')).body.error.code).toBe('internal_error');
  });

  test('a reason is carried only by a publish error whose code lists it', () => {
    const conflict = (reason?: 'number_held' | 'open_cap') => new PublishError('group_conflict', 'x', {}, undefined, reason);
    expect(errorViewV2(conflict('number_held')).body.error).toMatchObject({ code: 'group_conflict', reason: 'number_held' });
    expect(errorViewV2(conflict()).body.error).not.toHaveProperty('reason');
    // A code that lists no reasons drops one the error holds; an error of another class never has one.
    expect(errorViewV2(new PublishError('rate_limited', 'x', {}, 5, 'open_cap')).body.error).not.toHaveProperty('reason');
    expect(errorViewV2(new RegistryError('route_not_found', 'x')).body.error).not.toHaveProperty('reason');
  });
});
