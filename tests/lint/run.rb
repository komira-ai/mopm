# Superseded by //:lint_selftest (tests/drivers/lint_selftest_test.zig) on the build farm, which has no shell, Python, Ruby or pixi;
# kept for ci.yml until farm.yml has matched it. Change both together.
# Self-test for .github/scripts/{workflow_lint,hygiene}.rb. Run from the repository root:
#   ruby tests/lint/run.rb
# Each fixture is a minimal workflow with exactly one violation (see the table). Fixtures
# carry a .yml.fixture extension so GitHub never treats them as workflows. Two values would
# trip the real hygiene scan if stored literally, so fixtures hold placeholders that are
# substituted here at runtime: @@PRT@@ (the privileged PR trigger) and @@ACCT@@ (a
# 12-digit account-id-shaped number). The hygiene scan has no allow-list; nothing here
# needs one. Each case is materialized as ci.yml in a temp dir (a name not allowed id-token); promote_* fixtures become promote.yml, farm_* farm.yml, subject_* oidc-subject-check.yml, deploy_* deploy.yml and kpin_* kpin-update.yml (kpin_elsewhere stays ci.yml), release_* release.yml (release_elsewhere stays ci.yml).
require "open3"
require "tmpdir"

FIX = File.join(__dir__, "fixtures")
SUBST = {
  "@@PRT@@" => "pull_request_" + "target", "@@ACCT@@" => "1234" * 3,
  "@@AKID@@" => "AKIA" + "ABCDEFGHIJKLMNOP",
  "@@SECRETKEY@@" => "aws_secret_access_ke" + "y: abcdefghijklmnopqrst",
  "@@SESSTOKEN@@" => "aws_session_toke" + "n: abcdefghijklmnopqrst",
  "@@PRIVKEY@@" => "-----BEGIN RSA PRIVATE " + "KEY-----",
  "@@GHTOKEN@@" => "ghp_" + "abcdefghijklmnopqrstuvwxyz0123",
  "@@SLACK@@" => "xoxb-" + "1234567890",
  "@@JWT@@" => "eyJ" + "abcdefghij" + ".eyJ" + "abcdefghij" + ".sig",
  "@@ARN@@" => "arn:aws:iam::" + "1234" * 3 + ":role/x",
}
LINT = ".github/scripts/workflow_lint.rb"
HYG = ".github/scripts/hygiene.rb"
# fixture => { tool => [expected message substrings, one per expected failure line] }
CASES = {
  "clean" => { LINT => [], HYG => [] },
  "echo_secret_expr" => { LINT => ["run script references secrets.*", "interpolates an expression"] },
  "printf_token" => { LINT => ["prints a secret-bearing variable"] },
  "heredoc_role_arn" => { LINT => ["prints a secret-bearing variable"] },
  "vars_account" => { LINT => ["not vars"] },
  "id_token_write" => { LINT => ["id-token: write is not allowed"], HYG => ["an id-token permission is only allowed"] },
  "pr_target" => { LINT => ["is not allowed"], HYG => ["privileged PR-target trigger"] },
  "promote_missing_inherit" => { LINT => ["job gate must set secrets: inherit"] },
  "promote_inherit" => { LINT => [] },
  "promote_auto_ok" => { LINT => [] },
  "promote_no_concurrency" => { LINT => ["needs a concurrency group"] },
  "promote_cancel_true" => { LINT => ["needs a concurrency group"] },
  "promote_pull_request" => { LINT => ["triggers must be exactly push and workflow_dispatch"] },
  "inherit_elsewhere" => { LINT => ["secrets: inherit is not allowed outside promote.yml"] },
  "account_id_literal" => { HYG => ["12-digit number that looks like an account id"] },
  # farm.yml: komira's farm-connect and an id-token grant, for a pull request from this repository only.
  "farm_clean" => { LINT => [], HYG => [] },
  "farm_fork_unguarded" => { LINT => [], HYG => ["does not skip pull requests from forks"] },
  "farm_other_action" => { LINT => ["only GitHub-owned actions pinned by full SHA"], HYG => [] },
  # The rest were added with the Zig ports (tests/drivers/lint_selftest_test.zig runs the same table over the
  # same fixtures, and refuses to pass if the two tables differ): one fixture per rule the table did not reach.
  # hyg_*: the secret patterns of hygiene.rb (the values are built below, never stored).
  "hyg_aws_key" => { HYG => ["AWS access key id"] },
  "hyg_secret_key" => { HYG => ["AWS secret key assignment"] },
  "hyg_session_token" => { HYG => ["AWS session token"] },
  "hyg_private_key" => { HYG => ["private key block"] },
  "hyg_github_token" => { HYG => ["GitHub token"] },
  "hyg_slack_token" => { HYG => ["Slack token"] },
  "hyg_jwt" => { HYG => ["JWT"] },
  "hyg_arn" => { HYG => ["ARN carrying an account id", "12-digit number that looks like an account id"] },
  "environment_in_ci" => { LINT => [], HYG => ["may use a deployment environment"] },
  # workflow_lint.rb
  "no_permissions" => { LINT => ["top-level permissions must be set"] },
  "job_write" => { LINT => ["jobs.j.permissions.contents: write is not allowed"] },
  "unpinned_action" => { LINT => ["only GitHub-owned actions pinned by full SHA"] },
  "local_call_other" => { LINT => ["may only call a local workflow"] },
  "workflow_run_trigger" => { LINT => ["trigger workflow_run is not allowed"] },
  # subject_* become oidc-subject-check.yml and deploy_* deploy.yml
  "subject_clean" => { LINT => [], HYG => [] },
  "subject_aws" => { LINT => [], HYG => ["must not use AWS or secrets"] },
  "subject_env_prod" => { LINT => [], HYG => ["environment must be absent or beta"] },
  "subject_no_main_guard" => { LINT => [], HYG => ["is not restricted to refs/heads/main"] },
  "subject_push_trigger" => { LINT => [], HYG => ["triggers must be exactly workflow_dispatch"] },
  "deploy_clean" => { LINT => [], HYG => [] },
  "deploy_push_any_branch" => { LINT => [], HYG => ["push must be limited to branches: [main]"] },
  "deploy_no_environment" => { LINT => [], HYG => ["grants id-token without an environment"] },
  "deploy_pull_request" => { LINT => [], HYG => ["must not run on pull_request", "are not allowed in a workflow that can use id-token"] },
  # kpin-update.yml: the weekly pin update holds contents: write and pull-requests: write in its job, on a schedule or a manual run, and nowhere else.
  "kpin_clean" => { LINT => [], HYG => [] },
  "kpin_elsewhere" => { LINT => ["contents: write is not allowed", "pull-requests: write is not allowed"] },
  "kpin_pull_request" => { LINT => ["triggers must be exactly schedule and workflow_dispatch"] },
  "kpin_issues_write" => { LINT => ["issues: write is not allowed", "may hold only contents and pull-requests"] },
  "kpin_top_write" => { LINT => ["top-level permissions must be read-only", "permissions.contents: write is not allowed"] },
  # release.yml: a pushed v* tag publishes; contents, id-token and attestations write on its jobs, and nowhere else.
  "release_clean" => { LINT => [], HYG => [] },
  "release_elsewhere" => { LINT => ["contents: write is not allowed", "id-token: write is not allowed", "attestations: write is not allowed"], HYG => ["an id-token permission is only allowed"] },
  "release_branch_trigger" => { LINT => [], HYG => ["triggers must be exactly push of tags [v*], with no branches"] },
  "release_pull_request" => { LINT => [], HYG => ["triggers must be exactly push of tags [v*], with no branches"] },
  "release_environment" => { LINT => [], HYG => ["must not use secrets or an environment"] },
  "release_other_write" => { LINT => ["packages: write is not allowed"], HYG => [] },
  "release_unpinned_attest" => { LINT => ["only GitHub-owned actions pinned by full SHA"], HYG => [] },
  "release_calls_with_idtoken" => { LINT => [], HYG => ["calls a workflow and grants id-token"] },
}

bad = 0
CASES.each do |name, tools|
  text = File.read(File.join(FIX, "#{name}.yml.fixture"))
  SUBST.each { |k, v| text = text.gsub(k, v) }
  Dir.mktmpdir do |d|
    path = File.join(d, name.start_with?("promote") ? "promote.yml" : name.start_with?("farm") ? "farm.yml" : name.start_with?("subject") ? "oidc-subject-check.yml" : name.start_with?("deploy") ? "deploy.yml" : (name.start_with?("kpin") && name != "kpin_elsewhere") ? "kpin-update.yml" : (name.start_with?("release") && name != "release_elsewhere") ? "release.yml" : "ci.yml")
    File.write(path, text)
    tools.each do |tool, expected|
      out, st = Open3.capture2e("ruby", tool, path)
      lines = out.lines.map(&:chomp).reject(&:empty?)
      ok = if expected.empty?
        st.success? && lines.empty?
      else
        !st.success? && lines.size == expected.size && expected.all? { |e| lines.any? { |l| l.include?(e) } }
      end
      puts "#{ok ? 'ok  ' : 'FAIL'} #{name} / #{File.basename(tool)}"
      unless ok
        bad += 1
        warn "  expected #{expected.empty? ? 'pass' : expected.inspect}, got exit #{st.exitstatus}:\n  #{lines.join("\n  ")}"
      end
    end
  end
end
exit(bad.zero? ? 0 : 1)
