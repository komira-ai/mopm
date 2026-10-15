# Self-test for .github/scripts/{workflow_lint,hygiene}.rb. Run from the repository root:
#   ruby tests/lint/run.rb
# Each fixture is a minimal workflow with exactly one violation (see the table). Fixtures
# carry a .yml.fixture extension so GitHub never treats them as workflows. Two values would
# trip the real hygiene scan if stored literally, so fixtures hold placeholders that are
# substituted here at runtime: @@PRT@@ (the privileged PR trigger) and @@ACCT@@ (a
# 12-digit account-id-shaped number). The hygiene scan has no allow-list; nothing here
# needs one. Each case is materialized as ci.yml in a temp dir (a name not allowed id-token); promote_* fixtures become promote.yml, farm_* fixtures farm.yml and kpin_* fixtures kpin-update.yml (kpin_elsewhere stays ci.yml).
require "open3"
require "tmpdir"

FIX = File.join(__dir__, "fixtures")
SUBST = { "@@PRT@@" => "pull_request_" + "target", "@@ACCT@@" => "1234" * 3 }
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
  # kpin-update.yml: the weekly pin update holds contents: write and pull-requests: write in its job, on a schedule or a manual run, and nowhere else.
  "kpin_clean" => { LINT => [], HYG => [] },
  "kpin_elsewhere" => { LINT => ["contents: write is not allowed", "pull-requests: write is not allowed"] },
  "kpin_pull_request" => { LINT => ["triggers must be exactly schedule and workflow_dispatch"] },
  "kpin_issues_write" => { LINT => ["issues: write is not allowed", "may hold only contents and pull-requests"] },
  "kpin_top_write" => { LINT => ["top-level permissions must be read-only", "permissions.contents: write is not allowed"] },
}

bad = 0
CASES.each do |name, tools|
  text = File.read(File.join(FIX, "#{name}.yml.fixture"))
  SUBST.each { |k, v| text = text.gsub(k, v) }
  Dir.mktmpdir do |d|
    path = File.join(d, name.start_with?("promote") ? "promote.yml" : name.start_with?("farm") ? "farm.yml" : (name.start_with?("kpin") && name != "kpin_elsewhere") ? "kpin-update.yml" : "ci.yml")
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
