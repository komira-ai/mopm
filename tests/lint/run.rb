# Self-test for .github/scripts/{workflow_lint,hygiene}.rb. Run from the repository root:
#   ruby tests/lint/run.rb
# Each fixture is a minimal workflow with exactly one violation (see the table). Fixtures
# carry a .yml.fixture extension so GitHub never treats them as workflows. Two values would
# trip the real hygiene scan if stored literally, so fixtures hold placeholders that are
# substituted here at runtime: @@PRT@@ (the privileged PR trigger) and @@ACCT@@ (a
# 12-digit account-id-shaped number). The hygiene scan has no allow-list; nothing here
# needs one. Each case is materialized as ci.yml in a temp dir (a name not allowed id-token).
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
  "account_id_literal" => { HYG => ["12-digit number that looks like an account id"] },
}

bad = 0
CASES.each do |name, tools|
  text = File.read(File.join(FIX, "#{name}.yml.fixture"))
  SUBST.each { |k, v| text = text.gsub(k, v) }
  Dir.mktmpdir do |d|
    path = File.join(d, "ci.yml")
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
