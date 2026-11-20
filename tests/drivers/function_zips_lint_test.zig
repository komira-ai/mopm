//! The rules of tests/drivers/function_zips_lint.zig over the repository's promote.yml, function-zips.yml and deploy.yml (run with the
//! workflow lint, //:workflows), and each rule shown able to fail: a copy of the real file with one known defect must print the
//! message. The real files passing is workflow_lint_test.zig's "every workflow of the repository passes".

const std = @import("std");
const c = @import("lint_common.zig");
const wl = @import("workflow_lint.zig");
const Allocator = std.mem.Allocator;

const Repo = struct {
    tree: c.Tree,
    name: []const u8,
    from: []const u8,
    to: []const u8,
    /// A second change, for a file that must change in two places (empty: none).
    from2: []const u8 = "",
    to2: []const u8 = "",

    pub fn read(self: Repo, a: Allocator, name: []const u8) ![]u8 {
        const text = try self.tree.read(a, try std.fmt.allocPrint(a, ".github/workflows/{s}", .{name}));
        if (!std.mem.eql(u8, name, self.name)) return text;
        if (std.mem.indexOf(u8, text, self.from) == null) {
            std.debug.print("the faulty change does not apply to {s}: {s} is not in it\n", .{ name, self.from });
            return error.TestUnexpectedResult;
        }
        const once = try std.mem.replaceOwned(u8, a, text, self.from, self.to);
        if (self.from2.len == 0) return once;
        if (std.mem.indexOf(u8, once, self.from2) == null) {
            std.debug.print("the second faulty change does not apply to {s}: {s} is not in it\n", .{ name, self.from2 });
            return error.TestUnexpectedResult;
        }
        return std.mem.replaceOwned(u8, a, once, self.from2, self.to2);
    }
};

/// The repository's workflow `name` with `from` replaced by `to`: the whole-repository rules must print `want`, one line each.
fn expect(name: []const u8, from: []const u8, to: []const u8, want: []const []const u8) !void {
    return expect2(name, from, to, "", "", want);
}

fn expect2(name: []const u8, from: []const u8, to: []const u8, from2: []const u8, to2: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = c.Out.init(a);
    try wl.repoProblems(a, Repo{ .tree = try c.loadTree(a), .name = name, .from = from, .to = to, .from2 = from2, .to2 = to2 }, &out);
    try c.expectLines(name, out.items, want);
}

// ---- promote.yml ---------------------------------------------------------------------

const zips_job = "  function-zips:\n    uses: ./.github/workflows/function-zips.yml\n    permissions: { id-token: write, contents: read }\n";

test "promote.yml: the function-zips job is there, first, and beta-deploy waits for it" {
    try expect("promote.yml", zips_job ++ "\n", "", &.{"promote.yml: jobs [\"beta-deploy\", \"beta-e2e\", \"gamma-deploy\", \"gamma-e2e\", \"prod-deploy\", \"prod-smoke\"] differ from expected [\"beta-deploy\", \"beta-e2e\", \"function-zips\", \"gamma-deploy\", \"gamma-e2e\", \"prod-deploy\", \"prod-smoke\"]"});
    try expect("promote.yml", "  beta-deploy:\n    needs: function-zips\n", "  beta-deploy:\n", &.{"promote.yml: beta-deploy needs [], expected [\"function-zips\"]"});
    try expect("promote.yml", "    needs: function-zips\n", "    needs: [function-zips, beta-e2e]\n", &.{"promote.yml: beta-deploy needs [\"function-zips\", \"beta-e2e\"], expected [\"function-zips\"]"});
    try expect("promote.yml", zips_job, zips_job ++ "    needs: beta-e2e\n", &.{"promote.yml: function-zips needs [\"beta-e2e\"], expected []"});
}

test "promote.yml: the function-zips job calls function-zips.yml with no secret, no input and exactly its two permissions" {
    try expect("promote.yml", "    uses: ./.github/workflows/function-zips.yml\n", "    uses: ./.github/workflows/farm.yml\n", &.{"promote.yml: function-zips must call ./.github/workflows/function-zips.yml"});
    try expect("promote.yml", zips_job, zips_job ++ "    secrets: inherit\n", &.{"promote.yml: function-zips must not set secrets (it reads none)"});
    try expect("promote.yml", zips_job, zips_job ++ "    with: { stage: beta }\n", &.{"promote.yml: function-zips must not set with (it takes no input)"});
    try expect("promote.yml", "    permissions: { id-token: write, contents: read }\n\n  beta-deploy:", "    permissions: { id-token: write, contents: write }\n\n  beta-deploy:", &.{"promote.yml: function-zips must grant exactly id-token write and contents read"});
    try expect("promote.yml", "    permissions: { id-token: write, contents: read }\n\n  beta-deploy:", "\n  beta-deploy:", &.{"promote.yml: function-zips must grant exactly id-token write and contents read"});
    try expect("promote.yml", "    permissions: { id-token: write, contents: read }\n\n  beta-deploy:", "    permissions: { id-token: write, contents: read, actions: read }\n\n  beta-deploy:", &.{"promote.yml: function-zips must grant exactly id-token write and contents read"});
    try expect("promote.yml", zips_job, zips_job ++ "    continue-on-error: true\n", &.{"promote.yml: function-zips must not set continue-on-error"});
}

test "promote.yml: every deploy is given the artifact the one build uploads" {
    try expect("promote.yml", "with: { stage: gamma, function_zips: function-zips }", "with: { stage: gamma, function_zips: other }", &.{"promote.yml: gamma-deploy must pass function_zips: function-zips (every stage deploys the one build)"});
    try expect("promote.yml", "with: { stage: prod, function_zips: function-zips }", "with: { stage: prod }", &.{"promote.yml: prod-deploy must pass function_zips: function-zips (every stage deploys the one build)"});
    try expect("promote.yml", "with: { stage: beta, function_zips: function-zips }", "with: { stage: beta, function_zips: function-zips-beta }", &.{"promote.yml: beta-deploy must pass function_zips: function-zips (every stage deploys the one build)"});
}

// ---- function-zips.yml -----------------------------------------------------------------

const upload_step = "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n        with:\n          name: function-zips\n          path: ${{ runner.temp }}/function-zips\n          retention-days: 7\n          if-no-files-found: error\n";
const build_target = "//service/infra/stacks:function_zips --out";

test "function-zips.yml: only a call triggers it, and it is one job" {
    try expect("function-zips.yml", "on:\n  workflow_call:\n", "on:\n  pull_request:\n  workflow_call:\n", &.{"function-zips.yml: triggers must be exactly workflow_call (a promotion calls it and nothing else), got [\"pull_request\", \"workflow_call\"]"});
    try expect("function-zips.yml", "on:\n  workflow_call:\n", "on:\n  push:\n    branches: [main]\n", &.{"function-zips.yml: triggers must be exactly workflow_call (a promotion calls it and nothing else), got [\"push\"]"});
    try expect("function-zips.yml", "jobs:\n  build:\n", "jobs:\n  other:\n    runs-on: ubuntu-24.04\n  build:\n", &.{"function-zips.yml: expected exactly one job, got 2"});
    try expect("function-zips.yml", "    runs-on: ubuntu-24.04\n    timeout-minutes: 60\n", "    runs-on: ubuntu-24.04\n    timeout-minutes: 60\n    continue-on-error: true\n", &.{"function-zips.yml: the job must not set continue-on-error"});
}

test "function-zips.yml: the job runs on main alone" {
    const want = "function-zips.yml: the job must say `if: github.ref == 'refs/heads/main'` (no farm login, no build, off main)";
    try expect("function-zips.yml", "    if: github.ref == 'refs/heads/main'\n", "", &.{want});
    try expect("function-zips.yml", "    if: github.ref == 'refs/heads/main'\n", "    if: github.ref == 'refs/heads/main' || true\n", &.{want});
    try expect("function-zips.yml", "    if: github.ref == 'refs/heads/main'\n", "    if: always()\n", &.{want});
}

test "function-zips.yml: with no farm it fails, builds the one target remote-only, and every step is one line" {
    const want_build = "function-zips.yml: no step runs `./buck2 build --remote-only //service/infra/stacks:function_zips --out \"$RUNNER_TEMP/function-zips\"`";
    try expect("function-zips.yml", "Set it, or nothing deploys.\"; exit 1\n", "Set it, or nothing deploys.\"\n", &.{"function-zips.yml: no step fails (exit 1) when FARM_ADDRESS is not set: a deploy must never go out unbuilt"});
    try expect("function-zips.yml", build_target, "//service/infra/stacks:site --out", &.{want_build});
    try expect("function-zips.yml", "--out \"$RUNNER_TEMP/function-zips\"\n", "--out \"$RUNNER_TEMP/zips\"\n", &.{want_build});
    try expect("function-zips.yml", "build --remote-only //", "build //", &.{want_build});
    try expect("function-zips.yml", "      - name: Stop buck2\n", "      - name: Stop buck2\n        continue-on-error: true\n", &.{"function-zips.yml: step 5 must not set continue-on-error"});
}

test "function-zips.yml: no step runs more than one line" {
    const want3 = "function-zips.yml: step 3 runs more than one line; every step is one command (B4)";
    try expect("function-zips.yml", "        run: ./buck2 build --remote-only", "        run: |\n          ./buck2 kill\n          ./buck2 build --remote-only", &.{want3});
    try expect("function-zips.yml", "        run: ./buck2 build --remote-only //service/infra/stacks:function_zips --out \"$RUNNER_TEMP/function-zips\"\n", "        run: |\n          ./buck2 build --remote-only //service/infra/stacks:function_zips --out \"$RUNNER_TEMP/function-zips\"\n          ./buck2 kill\n", &.{want3});
    try expect("function-zips.yml", "Set it, or nothing deploys.\"; exit 1\n", "Set it, or nothing deploys.\"\n          exit 1\n", &.{"function-zips.yml: step 1 runs more than one line; every step is one command (B4)"});
}

test "function-zips.yml: the artifact is uploaded after the build, under the name every deploy downloads, for one to seven days" {
    try expect("function-zips.yml", upload_step, "", &.{"function-zips.yml: no step uploads the artifact with actions/upload-artifact"});
    try expect("function-zips.yml", "retention-days: 7\n", "retention-days: 30\n", &.{"function-zips.yml: the upload must set retention-days from 1 to 7, got 30"});
    try expect("function-zips.yml", "retention-days: 7\n", "retention-days: 0\n", &.{"function-zips.yml: the upload must set retention-days from 1 to 7, got 0"});
    try expect("function-zips.yml", "          retention-days: 7\n", "", &.{"function-zips.yml: the upload must set retention-days from 1 to 7, got "});
    try expect("function-zips.yml", "          name: function-zips\n", "          name: zips\n", &.{"function-zips.yml: the upload must set name: function-zips"});
    try expect("function-zips.yml", "          path: ${{ runner.temp }}/function-zips\n", "          path: ${{ runner.temp }}\n", &.{"function-zips.yml: the upload must set path: ${{ runner.temp }}/function-zips"});
    try expect("function-zips.yml", "if-no-files-found: error\n", "if-no-files-found: warn\n", &.{"function-zips.yml: the upload must set if-no-files-found: error"});
    try expect("function-zips.yml", "      - name: the farm is not configured\n", upload_step ++ "      - name: the farm is not configured\n", &.{"function-zips.yml: the upload (step 1) comes before the build (step 4)"});
}

// ---- deploy.yml --------------------------------------------------------------------------

const download_step = "      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2\n        with:\n          name: ${{ inputs.function_zips }}\n          path: ${{ runner.temp }}/function-zips\n";
const check_zips_cmd = "npx ts-node --prefer-ts-exts bin/function-zips.ts check-zips --zip-dir \"$ZIP_DIR\"";
const check_deployed_cmd = "npx ts-node --prefer-ts-exts bin/function-zips.ts check-deployed --stage \"$STAGE\" --zip-dir \"$ZIP_DIR\" --account \"$AWS_ACCOUNT_ID\" --region \"$AWS_DEFAULT_REGION\"";
const compare_head = "      - name: Compare each function's CodeSha256 with the sums\n";
const compare_step = compare_head ++ "        working-directory: service/infra/stacks\n        env:\n          STAGE: ${{ inputs.stage }}\n          ZIP_DIR: ${{ runner.temp }}/function-zips\n          AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}\n          AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}\n        run: " ++ check_deployed_cmd ++ "\n";
const check_step = "      - name: Check the function zips against their sums\n        working-directory: service/infra/stacks\n        env:\n          ZIP_DIR: ${{ runner.temp }}/function-zips\n        run: " ++ check_zips_cmd ++ "\n";
const deploy_head = "      - name: Deploy stacks\n";
const comparison_missing = "deploy.yml: no step runs `" ++ check_deployed_cmd ++ "`: the deploy skips the CodeSha256 comparison";

test "deploy.yml: only a call triggers it, and the artifact name is a required string input" {
    try expect("deploy.yml", "        value: ${{ jobs.deploy.outputs.deployed_sha }}\n", "        value: ${{ jobs.deploy.outputs.deployed_sha }}\n  workflow_dispatch:\n", &.{"deploy.yml: triggers must be exactly workflow_call (a manual deploy would have no zips; run promote.yml by hand), got [\"workflow_call\", \"workflow_dispatch\"]"});
    try expect("deploy.yml", "(built once by function-zips.yml)\n        required: true\n", "(built once by function-zips.yml)\n        required: false\n", &.{"deploy.yml: the input function_zips must be required and a string"});
    try expect("deploy.yml", "(built once by function-zips.yml)\n        required: true\n        type: string\n", "(built once by function-zips.yml)\n        required: true\n        type: boolean\n", &.{"deploy.yml: the input function_zips must be required and a string"});
    try expect("deploy.yml", "      function_zips:\n        description: Name of the workflow artifact that holds the Rust Lambda zips and their sums (built once by function-zips.yml)\n        required: true\n        type: string\n", "", &.{"deploy.yml: the input function_zips must be required and a string"});
}

test "deploy.yml: the zips are downloaded, checked against their sums before the deploy, and given to CDK" {
    try expect("deploy.yml", download_step, "", &.{"deploy.yml: deploy has no download-artifact step with name ${{ inputs.function_zips }} and path ${{ runner.temp }}/function-zips"});
    try expect("deploy.yml", "          name: ${{ inputs.function_zips }}\n", "          name: function-zips\n", &.{"deploy.yml: deploy has no download-artifact step with name ${{ inputs.function_zips }} and path ${{ runner.temp }}/function-zips"});
    try expect("deploy.yml", download_step, "      - run: ./buck2 build //service/infra/stacks:function_zips\n", &.{ "deploy.yml: deploy step 1 builds its own zips; a deploy takes the function-zips artifact", "deploy.yml: deploy has no download-artifact step with name ${{ inputs.function_zips }} and path ${{ runner.temp }}/function-zips" });
    try expect("deploy.yml", "          npm run build\n          test -f dist/http/lambda.js\n", "          npm run build\n          cargo build\n          test -f dist/http/lambda.js\n", &.{"deploy.yml: deploy step 5 builds its own zips; a deploy takes the function-zips artifact"});
    try expect("deploy.yml", "          npm run build\n          test -f dist/http/lambda.js\n", "          npm run build\n          zip_pack out.zip\n          test -f dist/http/lambda.js\n", &.{"deploy.yml: deploy step 5 builds its own zips; a deploy takes the function-zips artifact"});
    try expect("deploy.yml", "          npm run build\n          test -f dist/http/lambda.js\n", "          npm run build\n          lambda_zip out.zip\n          test -f dist/http/lambda.js\n", &.{"deploy.yml: deploy step 5 builds its own zips; a deploy takes the function-zips artifact"});
    try expect("deploy.yml", "      - name: Record deployed commit\n", "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9\n      - name: Record deployed commit\n", &.{"deploy.yml: deploy step 11 builds its own zips; a deploy takes the function-zips artifact"});
    try expect("deploy.yml", check_step, "", &.{"deploy.yml: no step runs `" ++ check_zips_cmd ++ "` before the deploy"});
    try expect("deploy.yml", "          ZIP_DIR: ${{ runner.temp }}/function-zips\n        run: npx ts-node --prefer-ts-exts bin/function-zips.ts check-zips", "          ZIP_DIR: ${{ runner.temp }}\n        run: npx ts-node --prefer-ts-exts bin/function-zips.ts check-zips", &.{"deploy.yml: deploy step 4 must set env ZIP_DIR to ${{ runner.temp }}/function-zips"});
    try expect("deploy.yml", "            --context \"commit=${GITHUB_SHA}\" \\\n            --context \"rustZipDir=${ZIP_DIR}\"\n", "            --context \"commit=${GITHUB_SHA}\"\n", &.{"deploy.yml: the cdk deploy step must pass `--context \"rustZipDir=${ZIP_DIR}\"`"});
    try expect("deploy.yml", "          ZIP_DIR: ${{ runner.temp }}/function-zips\n        run: |\n          set -euo pipefail\n", "        run: |\n          set -euo pipefail\n", &.{"deploy.yml: deploy step 9 must set env ZIP_DIR to ${{ runner.temp }}/function-zips"});
}

test "deploy.yml: after the deploy every function's CodeSha256 is compared with the sums, and nothing can skip it" {
    try expect("deploy.yml", compare_step, "", &.{comparison_missing});
    // Moved before the deploy: it would compare the functions of the last deploy, not this one.
    try expect("deploy.yml", deploy_head, compare_step ++ deploy_head, &.{"deploy.yml: the CodeSha256 comparison (step 9) runs before the cdk deploy step"});
    try expect("deploy.yml", compare_head, compare_head ++ "        continue-on-error: true\n", &.{"deploy.yml: deploy step 10 must not set continue-on-error"});
    try expect("deploy.yml", compare_head, compare_head ++ "        if: always()\n", &.{"deploy.yml: deploy step 10 must not have an if (the deploy cannot skip it)"});
    try expect("deploy.yml", "          STAGE: ${{ inputs.stage }}\n          ZIP_DIR: ${{ runner.temp }}/function-zips\n          AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}\n          AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}\n        run: " ++ check_deployed_cmd, "          STAGE: beta\n          ZIP_DIR: ${{ runner.temp }}/function-zips\n          AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}\n          AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}\n        run: " ++ check_deployed_cmd, &.{"deploy.yml: deploy step 10 must set env STAGE to ${{ inputs.stage }}"});
    try expect("deploy.yml", "          STAGE: ${{ inputs.stage }}\n          ZIP_DIR: ${{ runner.temp }}/function-zips\n          AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}\n          AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}\n        run: " ++ check_deployed_cmd, "          STAGE: ${{ inputs.stage }}\n          ZIP_DIR: ${{ runner.temp }}\n          AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}\n          AWS_DEFAULT_REGION: ${{ secrets.AWS_REGION }}\n        run: " ++ check_deployed_cmd, &.{"deploy.yml: deploy step 10 must set env ZIP_DIR to ${{ runner.temp }}/function-zips"});
    // The command itself: another sub-command, or one with a `|| true`, is not the comparison.
    try expect("deploy.yml", "check-deployed --stage", "check-zips --stage", &.{comparison_missing});
    try expect("deploy.yml", check_deployed_cmd ++ "\n", check_deployed_cmd ++ " || true\n", &.{comparison_missing});
}

test "deploy.yml: the download and the check of the zips come before the deploy, not after it" {
    const record = "      - name: Record deployed commit\n";
    try expect2("deploy.yml", download_step, "", record, download_step ++ record, &.{"deploy.yml: deploy downloads the function zips (step 10) after the cdk deploy step"});
    try expect2("deploy.yml", check_step, "", record, check_step ++ record, &.{"deploy.yml: the check of the zips against their sums (step 10) runs after the cdk deploy step"});
}

test "deploy.yml: a deploy with no cdk deploy step is refused" {
    try expect("deploy.yml", "          npx cdk deploy --all", "          npx cdk synth --all", &.{"deploy.yml: deploy has no cdk deploy step"});
}
