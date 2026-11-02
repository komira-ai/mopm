import * as fs from 'fs';
import * as path from 'path';
import { PUBLISH_ROUTES, READ_ROUTES } from '../lib/api-stack';

/**
 * The API package keeps an inventory of its readers of version rows and the leak case that covers each
 * (service/api/test/fixtures/group-inventory.json, checked by test/group-guards.test.ts there). This is the other side:
 * every read and publish route the API handler is deployed with must be in that inventory, and the inventory lists no
 * route that is not deployed. A route added to the stack without a leak case fails here.
 */

const INVENTORY = path.resolve(__dirname, '../../../api/test/fixtures/group-inventory.json');
const listed = (JSON.parse(fs.readFileSync(INVENTORY, 'utf8')) as { routes: Array<{ route: string }> }).routes.map((r) => r.route).sort();

describe('the routes of the API handler and the leak inventory', () => {
  const deployed = [...READ_ROUTES.map((p) => `GET ${p}`), ...PUBLISH_ROUTES.map((r) => `${r.method} ${r.path}`)].sort();

  test('the routes are read (an empty list proves nothing)', () => {
    expect(deployed.length).toBeGreaterThanOrEqual(10);
    expect(deployed).toContain('GET /api/v1/packages/{name}/versions');
    expect(deployed).toContain('PUT /api/v1/packages/{name}/{version}/yank');
  });

  test('every deployed read and publish route is in the inventory, and nothing else is', () => {
    expect(listed).toEqual(deployed);
  });
});
