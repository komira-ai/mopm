import * as fs from 'fs';
import * as path from 'path';
import { STAGES, assertStage, edgeOriginSecretName, isDisposable, oauthSecretName, parseTutorialConfig, readTutorialConfig, stageConfig } from '../lib/config';

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
      ...(json.tutorial !== undefined ? { tutorial: c.tutorial } : {}),
    });
  });

  test('passes the key check, and its tutorial block (if any) is what the stack configuration carries', () => {
    expect(readTutorialConfig(stage)).toEqual(parseTutorialConfig(file, json));
    expect(c.tutorial).toEqual(readTutorialConfig(stage));
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

describe('the configuration file key check', () => {
  const base = { stage: 'beta', siteDomain: 'beta.mopm.dev', condaDomain: 'conda.beta.mopm.dev', apiDomain: 'api.beta.mopm.dev', hostedZoneName: 'beta.mopm.dev', disposable: true };
  const F = 'service/config/beta.json';

  test('a file without a tutorial block has no tutorial configuration', () => {
    expect(parseTutorialConfig(F, base)).toBeUndefined();
  });

  test('accepts the optional tutorial fields, each alone and all together', () => {
    expect(parseTutorialConfig(F, { ...base, tutorial: {} })).toEqual({});
    expect(parseTutorialConfig(F, { ...base, tutorial: { e2bTemplateId: 'abc-12_x' } })).toEqual({ e2bTemplateId: 'abc-12_x' });
    expect(parseTutorialConfig(F, { ...base, tutorial: { e2bDomain: 'e2b.app' } })).toEqual({ e2bDomain: 'e2b.app' });
    expect(parseTutorialConfig(F, { ...base, tutorial: { sandboxTimeoutS: 1 } })).toEqual({ sandboxTimeoutS: 1 });
    const all = { e2bTemplateId: 't', e2bDomain: 'sandbox.example.com', sandboxTimeoutS: 3600 };
    expect(parseTutorialConfig(F, { ...base, tutorial: all })).toEqual(all);
  });

  test('refuses an unknown key, at the top and in the tutorial block, naming it and the allowed keys', () => {
    expect(() => parseTutorialConfig(F, { ...base, apiDomian: 'x' })).toThrow(
      `${F}: unknown key 'apiDomian'; the keys are stage, siteDomain, condaDomain, apiDomain, hostedZoneName, disposable, tutorial`,
    );
    expect(() => parseTutorialConfig(F, { ...base, tutorial: { e2bTemplateID: 'x' } })).toThrow(
      `${F}: unknown key 'tutorial.e2bTemplateID'; the keys are e2bTemplateId, e2bDomain, sandboxTimeoutS`,
    );
  });

  test.each([null, [], 'x', 1])('refuses a file that is not an object (%p)', (v) => {
    expect(() => parseTutorialConfig(F, v)).toThrow(`${F}: must be a JSON object`);
  });

  test.each([null, [], 'x', 1])('refuses a tutorial block that is not an object (%p)', (v) => {
    expect(() => parseTutorialConfig(F, { ...base, tutorial: v })).toThrow(`${F}: 'tutorial' must be an object`);
  });

  test.each(['', 'a b', 'a/b', 7, null])('refuses the template id %p', (v) => {
    expect(() => parseTutorialConfig(F, { ...base, tutorial: { e2bTemplateId: v } })).toThrow(
      `${F}: 'tutorial.e2bTemplateId' must be a non-empty string of letters, digits, '-' and '_'`,
    );
  });

  test.each(['', 'e2b', 'https://e2b.app', 'e2b.app:443', 'e2b.app/x', 'E2B.app', '-e2b.app', 'e2b-.app', 'e2b..app', 1])('refuses the domain %p', (v) => {
    expect(() => parseTutorialConfig(F, { ...base, tutorial: { e2bDomain: v } })).toThrow(
      `${F}: 'tutorial.e2bDomain' must be a host name such as e2b.app (no scheme, port or path)`,
    );
  });

  test.each([0, -1, 1.5, '1800', null, Number.NaN])('refuses the timeout %p', (v) => {
    expect(() => parseTutorialConfig(F, { ...base, tutorial: { sandboxTimeoutS: v } })).toThrow(
      `${F}: 'tutorial.sandboxTimeoutS' must be a whole number of seconds above 0`,
    );
  });
});
