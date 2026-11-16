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

/**
 * The two stage checks, over HTTP, with no token. `index_versions` is read from the stage's `/index/config.json` (absent: the
 * one `index_version`). `/api/v2` is served when `config.json` names `api_v2_url` and `<api_v2_url>/health` answers 200; the
 * spec has `/api/v1` refuse flat creation from then on. (A claim sent to `/api/v1` would not do as a check: the route reads the
 * token before the name, so a tokenless claim answers 401 whatever the stage runs.)
 */
export async function stageChecks(configUrl: string, http: HttpFn = defaultHttp): Promise<StageChecks> {
  const r = await http(configUrl, { method: 'GET', headers: { accept: 'application/json' } });
  if (r.status !== 200) throw new Error(`${configUrl} answered ${r.status}`);
  const config = JSON.parse(await r.text()) as { index_version?: number; index_versions?: number[]; api_v2_url?: string };
  const index_versions = config.index_versions ?? (config.index_version === undefined ? [] : [config.index_version]);
  if (typeof config.api_v2_url !== 'string') return { index_versions, api_v2_served: false };
  const health = await http(`${config.api_v2_url.replace(/\/$/, '')}/health`, { method: 'GET', headers: { accept: 'application/json' } });
  return { index_versions, api_v2_served: health.status === 200 };
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
