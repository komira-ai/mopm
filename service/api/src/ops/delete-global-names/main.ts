import { authTablesFor, DynamoAuthStore } from '../../auth/dynamo-auth-store';
import { DynamoStore, tablesFor } from '../../dynamo-store';
import { CloudFrontInvalidator, defaultHttp, S3Channel, type HttpFn } from '../../publish/aws';
import { documentClient, regionOf } from '../../publish/wiring';
import { parseDeleteArgs, runDelete, type DeleteArgs, type DeleteDeps, type StageChecks } from './tool';

/**
 * The entry point of the held deletion tool (see tool.ts), bundled to dist/ops/delete-global-names/bin.js. It builds the
 * real adapters from the flags and the AWS credentials of the environment, and nothing else: the behaviour is in tool.ts,
 * which is what the tests run.
 */

/** A flat name nobody may claim, in the grammar: the probe that `/api/v1` refuses flat creation. */
export const PROBE_NAME = 'delete_global_probe';

/**
 * The two stage checks, over HTTP. `index_versions` is read from the stage's `/index/config.json` (absent: the one
 * `index_version`). `/api/v1` is asked to claim PROBE_NAME with no token: it refuses flat creation only when it answers
 * 403 `name_reserved`. A request without a token creates nothing whatever the stage runs, so the probe is harmless; any
 * other answer (401 included) counts as "not refused", and the tool refuses to delete.
 */
export async function stageChecks(configUrl: string, http: HttpFn = defaultHttp): Promise<StageChecks> {
  const r = await http(configUrl, { method: 'GET', headers: { accept: 'application/json' } });
  if (r.status !== 200) throw new Error(`${configUrl} answered ${r.status}`);
  const config = JSON.parse(await r.text()) as { index_version?: number; index_versions?: number[]; api_url?: string };
  const index_versions = config.index_versions ?? (config.index_version === undefined ? [] : [config.index_version]);
  if (!config.api_url) throw new Error(`${configUrl} names no api_url`);
  const claim = await http(`${config.api_url.replace(/\/$/, '')}/packages/${PROBE_NAME}/claim`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  const body = await claim.text();
  let code: unknown;
  try {
    code = (JSON.parse(body) as { error?: { code?: unknown } }).error?.code;
  } catch {
    code = undefined;
  }
  return { index_versions, v1_refuses_flat_creation: claim.status === 403 && code === 'name_reserved' };
}

/** The adapters for a stage. */
export function realDeps(args: DeleteArgs): DeleteDeps {
  const region = args.region ?? regionOf({});
  const doc = documentClient();
  return {
    registry: new DynamoStore(doc, tablesFor(args.stage)),
    publishers: new DynamoAuthStore(doc, authTablesFor(args.stage)),
    bucket: new S3Channel(args.bucket, { region }),
    invalidator: new CloudFrontInvalidator(args.distribution, { region }),
    checks: () => stageChecks(args.configUrl),
    out: (line) => console.log(JSON.stringify(line)),
  };
}

/** Parse, run, and turn a failure into a message and a status. `build` makes the adapters (the tests give fakes). */
export async function main(argv: readonly string[], build: (args: DeleteArgs) => DeleteDeps = realDeps): Promise<number> {
  try {
    const args = parseDeleteArgs(argv);
    return await runDelete(args, build(args));
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    return 1;
  }
}
