import * as fs from 'fs';
import * as path from 'path';
import { STAGES, assertStage, edgeOriginSecretName, isDisposable, oauthSecretName, stageConfig } from '../lib/config';

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

test('a stage name is one of the three; anything else is refused, naming them and what it got', () => {
  for (const s of STAGES) expect(assertStage(s)).toBe(s);
  for (const bad of ['', 'Beta', 'dev', 'prod ']) {
    expect(() => assertStage(bad)).toThrow(`stage must be one of beta, gamma, prod; got '${bad}'`);
  }
});

test("each stage's secrets are under mopm/<stage>/, the edge-origin one included", () => {
  expect(STAGES.map(edgeOriginSecretName)).toEqual(['mopm/beta/edge-origin', 'mopm/gamma/edge-origin', 'mopm/prod/edge-origin']);
  for (const s of STAGES) expect(edgeOriginSecretName(s)).not.toBe(oauthSecretName(s));
});
