import * as fs from 'fs';
import * as path from 'path';
import { ownedPackagesFrom } from '../src/auth';
import * as fake from './auth-fake-doc';

// The strict DynamoDB double is only worth anything if it is never more generous than the deployed role. The role's
// grants are AUTH_GRANTS in service/infra/stacks/lib/api-stack.ts; the stacks test pins that constant to
// fixtures/lambda-auth-grants.json (test 'AUTH_GRANTS equals the grants the adapter tests are enforced under'), and this
// file pins the double to the same JSON. So CDK == JSON == double. An extra, hand-written grant in the double (it once
// had one for the owners index that the deployed role lacked, so POST /me/tokens passed here and failed with
// AccessDenied when deployed) would make the double broader than the role and is refused here.
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/lambda-auth-grants.json'), 'utf8'));
const exported = fake as unknown as Record<string, unknown>;

describe('the DynamoDB double is not broader than the deployed role', () => {
  test('the only grants it exports are the ones read from lambda-auth-grants.json', () => {
    expect(Object.keys(exported).filter((k) => /GRANTS/.test(k))).toEqual(['LAMBDA_GRANTS']);
    expect(exported.LAMBDA_GRANTS).toEqual(fixture);
  });

  test('the owners index is allowed only because the JSON lists it: without it the query is AccessDenied', async () => {
    const grants = { ...fixture };
    delete grants.owners;
    const doc = new fake.FakeAuthDoc({ grants });
    await expect(ownedPackagesFrom(doc, 'mopm-t-owners')(1)).rejects.toMatchObject({ name: 'AccessDeniedException' });
  });

  test('the JSON grants the owners index to the account-token path (Query on by_github_id)', async () => {
    expect(fixture.owners).toEqual({ actions: ['dynamodb:GetItem', 'dynamodb:Query'], indexes: ['by_github_id'] });
    const doc = new fake.FakeAuthDoc({ grants: fixture });
    doc.seed('owners', { name: 'alpha', github_id: '7', github_id_num: 7 });
    expect(await ownedPackagesFrom(doc, 'mopm-t-owners')(7)).toEqual(['alpha']);
  });
});
