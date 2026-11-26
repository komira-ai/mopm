# Pull request farm builds do not download their outputs

Status: proposal, for review. This is a client workaround; the farm-side causes of the slow build are tracked separately.

## Problem

`.github/workflows/farm.yml` runs `./buck2 build` on the farm. The farm answers 99% of the actions from its cache (a run of
#335 reported `Commands: 2449 (cached: 2447, remote: 2, local: 0)`), yet the same run reported `Network: down 4.2GiB` and took
43 minutes: Buck2 materializes every requested output on the runner, and the runner reaches the farm over a slow path
(about 1.7 MB/s measured in that run). The farm sits idle while the runner downloads. A pull request check reads only the
build's success; nothing after the build step uses the outputs (the following step reads the summary line of the log).

## Change

For a pull request, the build step passes `--materializations=none`. Buck2 then finishes each action on the farm and does not
fetch the outputs to the runner. A push to main keeps the default, so the build of main still materializes what it builds.
Nothing else changes: the target set, the `local: 0` check and the farm login are as before.

## What this does not fix

- Connection resets reach the clients from the edge or the path to it; which hop closes is not yet known (the edge's
  `kbf-reapi` listener has no access log). Keepalive settings (`grpc_keepalive_timeout_secs` in the farm's machine buckconfig,
  and an http2 keepalive timeout in kbf) are deliberately not changed here: they change only after the access log shows which
  side closes. Fewer downloaded bytes also means fewer streams exposed to a reset.
- The `ttl = 0` text of "Error materializing files" is a constant of the pinned Buck2 release's RE client, not a farm report;
  the failures behind it are the resets above. With no materialization on pull requests, those failures no longer occur there.

## Compatibility and failure modes

- A failure to build is still a failed check: `--materializations=none` skips only the download of outputs.
- A pull request check no longer proves that every output can be fetched from the farm. A push to main materializes, so that is
  still exercised after the merge.
- Rollback is removing the flag.

## Test

Workflow files have no unit tests beyond the workflow lint (`tests/drivers/workflow_lint_test.zig`), which this change keeps
green; the effect is read from the next pull request's farm run: the summary line's `Network: down` drops from GiB to a
few MiB. This is measured on that run, not inferred here.
