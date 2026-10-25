/**
 * Limits of the publish pipeline. The defaults are the CEO's: a package is at most 100 MB (decimal), a project
 * holds at most 10 GB (a full project blocks new publishes and nothing is ever deleted to make room), and rate
 * limits are generous (a CI pushing 100 versions a day is normal). The rate limits are configurable per stage.
 */
export interface PublishConfig {
  /** Declared size of one archive, in bytes. */
  maxArchiveBytes: number;
  /** All bytes of the non-tombstoned files of one package. */
  projectQuotaBytes: number;
  /** Validity of a presigned upload URL (the contract says at most five minutes). */
  uploadUrlTtlSeconds: number;
  /** How long an upload record can be committed after begin. */
  uploadRecordTtlSeconds: number;
  /** begin-upload calls per account (GitHub id) per UTC day. */
  ratePerAccountPerDay: number;
  /** begin-upload calls per token per UTC day. */
  ratePerTokenPerDay: number;
  /** Members in one group. */
  groupMaxMembers: number;
  /** Declared bytes of all the files of one group. */
  groupMaxBytes: number;
  /** Groups an actor may have open at once. */
  groupOpenPerActor: number;
  /** Files created in groups per account per UTC day: a counter of its own, so groups never use up the singles' budget. */
  groupRatePerAccountPerDay: number;
  /** Files created in groups per token per UTC day. */
  groupRatePerTokenPerDay: number;
  /** Hours from the creation of a group (or its reopening) to its deadline; the quarantine prefix expires after a day, so this stays well below 24. */
  groupDeadlineHours: number;
  /** Time a create call spends reserving members before it answers `reserving` (milliseconds; the API Lambda's timeout is 10 s). */
  groupCreateBudgetMs: number;
  /** Hours the validator reserves for a group out of the quarantine prefix's day: an upload older than 24 minus this is rejected before anything is copied. */
  groupValidateHours: number;
  /** Milliseconds one validator invocation spends starting members before it saves its progress and queues itself again (the Lambda's timeout is 300 s). */
  groupBudgetMs: number;
  /** Other groups of the same actor that one create may supersede. */
  groupSupersedeMax: number;
}

export const DEFAULT_PUBLISH_CONFIG: PublishConfig = {
  maxArchiveBytes: 100_000_000,
  projectQuotaBytes: 10_000_000_000,
  uploadUrlTtlSeconds: 300,
  uploadRecordTtlSeconds: 86_400,
  ratePerAccountPerDay: 2000,
  ratePerTokenPerDay: 1000,
  groupMaxMembers: 500,
  groupMaxBytes: 20_000_000_000,
  groupOpenPerActor: 5,
  // Charged per file, and a retry of a dead group is charged again: sized for a few attempts of a full group (500 members).
  groupRatePerAccountPerDay: 40_000,
  groupRatePerTokenPerDay: 20_000,
  groupDeadlineHours: 12,
  groupCreateBudgetMs: 7000,
  groupValidateHours: 6,
  groupBudgetMs: 240_000,
  groupSupersedeMax: 3,
};

function intFrom(env: Record<string, string | undefined>, name: string, fallback: number, min: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  if (!/^[0-9]+$/.test(raw) || Number(raw) < min) throw new Error(`${name} must be an integer of at least ${min}`);
  return Number(raw);
}

/** The Lambda environment (set by the stack) over the defaults. A bad value stops the cold start. */
export function publishConfigFromEnv(env: Record<string, string | undefined> = process.env): PublishConfig {
  const d = DEFAULT_PUBLISH_CONFIG;
  return {
    maxArchiveBytes: intFrom(env, 'MOPM_MAX_ARCHIVE_BYTES', d.maxArchiveBytes, 1),
    projectQuotaBytes: intFrom(env, 'MOPM_PROJECT_QUOTA_BYTES', d.projectQuotaBytes, 1),
    uploadUrlTtlSeconds: Math.min(300, intFrom(env, 'MOPM_UPLOAD_URL_TTL_SECONDS', d.uploadUrlTtlSeconds, 30)),
    uploadRecordTtlSeconds: intFrom(env, 'MOPM_UPLOAD_RECORD_TTL_SECONDS', d.uploadRecordTtlSeconds, 300),
    ratePerAccountPerDay: intFrom(env, 'MOPM_RATE_PER_ACCOUNT_DAY', d.ratePerAccountPerDay, 1),
    ratePerTokenPerDay: intFrom(env, 'MOPM_RATE_PER_TOKEN_DAY', d.ratePerTokenPerDay, 1),
    groupMaxMembers: intFrom(env, 'MOPM_GROUP_MAX_MEMBERS', d.groupMaxMembers, 1),
    groupMaxBytes: intFrom(env, 'MOPM_GROUP_MAX_BYTES', d.groupMaxBytes, 1),
    groupOpenPerActor: intFrom(env, 'MOPM_GROUP_OPEN_PER_ACTOR', d.groupOpenPerActor, 1),
    groupRatePerAccountPerDay: intFrom(env, 'MOPM_GROUP_RATE_PER_ACCOUNT_DAY', d.groupRatePerAccountPerDay, 1),
    groupRatePerTokenPerDay: intFrom(env, 'MOPM_GROUP_RATE_PER_TOKEN_DAY', d.groupRatePerTokenPerDay, 1),
    // Under the 24 hours the quarantine prefix keeps an upload (a group's files are copied from it after the deadline's work begins).
    groupDeadlineHours: Math.min(18, intFrom(env, 'MOPM_GROUP_DEADLINE_HOURS', d.groupDeadlineHours, 1)),
    groupCreateBudgetMs: Math.min(9000, intFrom(env, 'MOPM_GROUP_CREATE_BUDGET_MS', d.groupCreateBudgetMs, 100)),
    // The quarantine prefix keeps an upload for a day; the validator's hours come out of it, so they are at most 23.
    groupValidateHours: Math.min(23, intFrom(env, 'MOPM_GROUP_VALIDATE_HOURS', d.groupValidateHours, 1)),
    // Under the 300 s the Lambda may run, with room for the member in flight.
    groupBudgetMs: Math.min(270_000, intFrom(env, 'MOPM_GROUP_BUDGET_MS', d.groupBudgetMs, 1)),
    groupSupersedeMax: d.groupSupersedeMax,
  };
}
