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

  test('the group limits: a group of 500 members and 20 GB, five open groups, counters of their own, a deadline well under the quarantine\'s day', () => {
    expect(DEFAULT_PUBLISH_CONFIG).toMatchObject({
      groupMaxMembers: 500,
      groupMaxBytes: 20_000_000_000,
      groupOpenPerActor: 5,
      groupRatePerAccountPerDay: 40_000,
      groupRatePerTokenPerDay: 20_000,
      groupDeadlineHours: 12,
      groupCreateBudgetMs: 7000,
      groupSupersedeMax: 3,
    });
    expect(publishConfigFromEnv({ MOPM_GROUP_MAX_MEMBERS: '10', MOPM_GROUP_MAX_BYTES: '99', MOPM_GROUP_OPEN_PER_ACTOR: '2', MOPM_GROUP_RATE_PER_ACCOUNT_DAY: '7', MOPM_GROUP_RATE_PER_TOKEN_DAY: '6' })).toMatchObject({
      groupMaxMembers: 10,
      groupMaxBytes: 99,
      groupOpenPerActor: 2,
      groupRatePerAccountPerDay: 7,
      groupRatePerTokenPerDay: 6,
    });
    // The deadline cannot be set past the quarantine prefix's day, and the creation budget stays under the Lambda's ten seconds.
    expect(publishConfigFromEnv({ MOPM_GROUP_DEADLINE_HOURS: '48', MOPM_GROUP_CREATE_BUDGET_MS: '60000' })).toMatchObject({ groupDeadlineHours: 18, groupCreateBudgetMs: 9000 });
    expect(() => publishConfigFromEnv({ MOPM_GROUP_MAX_MEMBERS: '0' })).toThrow('MOPM_GROUP_MAX_MEMBERS');
  });

  test('the group validator: six hours of the quarantine day reserved for validation, and a time budget under the Lambda\'s 300 seconds', () => {
    expect(DEFAULT_PUBLISH_CONFIG).toMatchObject({ groupValidateHours: 6, groupBudgetMs: 240_000 });
    expect(publishConfigFromEnv({ MOPM_GROUP_VALIDATE_HOURS: '3', MOPM_GROUP_BUDGET_MS: '60000' })).toMatchObject({ groupValidateHours: 3, groupBudgetMs: 60_000 });
    // The hours cannot be more than the day has, and the budget cannot reach the function's timeout.
    expect(publishConfigFromEnv({ MOPM_GROUP_VALIDATE_HOURS: '99', MOPM_GROUP_BUDGET_MS: '900000' })).toMatchObject({ groupValidateHours: 23, groupBudgetMs: 270_000 });
    expect(() => publishConfigFromEnv({ MOPM_GROUP_VALIDATE_HOURS: '0' })).toThrow('MOPM_GROUP_VALIDATE_HOURS');
    expect(() => publishConfigFromEnv({ MOPM_GROUP_BUDGET_MS: 'soon' })).toThrow('MOPM_GROUP_BUDGET_MS');
  });

  test('the upload URL lifetime cannot be configured above the contract\'s five minutes', () => {
    expect(publishConfigFromEnv({ MOPM_UPLOAD_URL_TTL_SECONDS: '3600' }).uploadUrlTtlSeconds).toBe(300);
    expect(publishConfigFromEnv({ MOPM_UPLOAD_URL_TTL_SECONDS: '60' }).uploadUrlTtlSeconds).toBe(60);
  });
});
