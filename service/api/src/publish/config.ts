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
}

export const DEFAULT_PUBLISH_CONFIG: PublishConfig = {
  maxArchiveBytes: 100_000_000,
  projectQuotaBytes: 10_000_000_000,
  uploadUrlTtlSeconds: 300,
  uploadRecordTtlSeconds: 86_400,
  ratePerAccountPerDay: 2000,
  ratePerTokenPerDay: 1000,
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
  };
}
