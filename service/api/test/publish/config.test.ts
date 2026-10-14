import { DEFAULT_PUBLISH_CONFIG, publishConfigFromEnv } from '../../src/publish/config';
import { DEFAULT_LIMITS } from '../../src/validate/limits';

describe('publish configuration', () => {
  test('the defaults are the CEO\'s: 100 MB a package (the same number the validator enforces), 10 GB a project', () => {
    expect(DEFAULT_PUBLISH_CONFIG.maxArchiveBytes).toBe(100_000_000);
    expect(DEFAULT_PUBLISH_CONFIG.maxArchiveBytes).toBe(DEFAULT_LIMITS.maxArchiveBytes);
    expect(DEFAULT_PUBLISH_CONFIG.projectQuotaBytes).toBe(10_000_000_000);
    expect(DEFAULT_PUBLISH_CONFIG.uploadUrlTtlSeconds).toBeLessThanOrEqual(300); // the contract: at most five minutes
    expect(DEFAULT_PUBLISH_CONFIG.ratePerAccountPerDay).toBeGreaterThanOrEqual(1000);
  });

  test('an empty environment gives the defaults; set values override them', () => {
    expect(publishConfigFromEnv({})).toEqual(DEFAULT_PUBLISH_CONFIG);
    expect(publishConfigFromEnv({ MOPM_RATE_PER_ACCOUNT_DAY: '50', MOPM_RATE_PER_TOKEN_DAY: '7', MOPM_PROJECT_QUOTA_BYTES: '123' })).toMatchObject({
      ratePerAccountPerDay: 50,
      ratePerTokenPerDay: 7,
      projectQuotaBytes: 123,
    });
  });

  test('a bad value stops the cold start instead of silently disabling a limit', () => {
    for (const bad of ['abc', '-1', '0', '1.5', ' 5']) expect(() => publishConfigFromEnv({ MOPM_RATE_PER_ACCOUNT_DAY: bad })).toThrow('MOPM_RATE_PER_ACCOUNT_DAY');
  });

  test('the upload URL lifetime cannot be configured above the contract\'s five minutes', () => {
    expect(publishConfigFromEnv({ MOPM_UPLOAD_URL_TTL_SECONDS: '3600' }).uploadUrlTtlSeconds).toBe(300);
    expect(publishConfigFromEnv({ MOPM_UPLOAD_URL_TTL_SECONDS: '60' }).uploadUrlTtlSeconds).toBe(60);
  });
});
