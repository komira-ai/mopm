import { Match } from 'aws-cdk-lib/assertions';
import { HEALTH_HANDLER_SOURCE } from '../lib/api-stack';
import { STAGES } from '../lib/config';
import { tpl } from './util';

describe.each(STAGES)('ApiStack %s', (stage) => {
  const { api: t } = tpl(stage);
  const host = stage === 'prod' ? 'api.mopm.dev' : `api.${stage}.mopm.dev`;

  test('exactly one Node.js Lambda', () => {
    t.resourceCountIs('AWS::Lambda::Function', 1);
    t.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'nodejs20.x',
      Environment: { Variables: { MOPM_STAGE: stage, MOPM_VERSION: '1.2.3', MOPM_COMMIT: 'c0ffee' } },
    });
  });

  test('HTTP API serves GET /api/v1/health only, with the default endpoint disabled', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::Api', { ProtocolType: 'HTTP', DisableExecuteApiEndpoint: true });
    t.resourceCountIs('AWS::ApiGatewayV2::Route', 1);
    t.hasResourceProperties('AWS::ApiGatewayV2::Route', { RouteKey: 'GET /api/v1/health' });
  });

  test('custom domain with a DNS-validated certificate', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::DomainName', { DomainName: host });
    t.hasResourceProperties('AWS::CertificateManager::Certificate', { DomainName: host, ValidationMethod: 'DNS' });
    t.hasResourceProperties('AWS::Route53::RecordSet', Match.objectLike({ Name: `${host}.`, Type: 'A' }));
  });

  test('log group has bounded retention', () => {
    t.hasResourceProperties('AWS::Logs::LogGroup', { RetentionInDays: 30 });
  });

  test('handler returns the stage, version and commit as JSON', async () => {
    const mod: { exports: any } = { exports: {} };
    new Function('exports', 'process', HEALTH_HANDLER_SOURCE)(mod.exports, {
      env: { MOPM_STAGE: stage, MOPM_VERSION: '1.2.3', MOPM_COMMIT: 'c0ffee' },
    });
    const res = await mod.exports.handler();
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({ stage, version: '1.2.3', commit: 'c0ffee' });
  });
});
