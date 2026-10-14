import * as fs from 'fs';
import * as path from 'path';
import { STAGES, isDisposable, stageConfig } from '../lib/config';

// service/config/<stage>.json is what the e2e workflow reads to find the API host. It must say exactly what the
// stacks deploy, or e2e would test a host the deploy never created.
describe.each(STAGES)('service/config/%s.json', (stage) => {
  const file = path.join(__dirname, '..', '..', '..', 'config', `${stage}.json`);
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  const c = stageConfig(stage);

  test('matches the stack configuration', () => {
    expect(json).toEqual({
      stage,
      siteDomain: c.siteDomain,
      condaDomain: c.condaDomain,
      apiDomain: c.apiDomain,
      hostedZoneName: c.hostedZoneName,
      disposable: isDisposable(stage),
    });
  });

  test('holds no account id, ARN or region', () => {
    const text = fs.readFileSync(file, 'utf8');
    expect(text).not.toMatch(/\d{12}|arn:|[a-z]{2}-[a-z]+-\d/);
  });
});
