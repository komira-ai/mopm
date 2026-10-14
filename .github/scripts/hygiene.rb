# Public-repo hygiene. Run from the repository root: ruby .github/scripts/hygiene.rb
# Scans every tracked text file. There is no allow-list: a test that needs an account id
# must build it at runtime. Patterns use bracket tricks so this file does not match itself.
require "yaml"

bad = 0
fail_ = ->(msg) { warn "hygiene: #{msg}"; bad += 1 }

text_rules = {
  "AWS access key id" => /\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ABIA|ACCA)[0-9A-Z]{16}\b/,
  "AWS secret key assignment" => /aws_secret_access_ke[y]\s*[=:]\s*\S{20,}/i,
  "AWS session token" => /aws_session_toke[n]\s*[=:]\s*\S{20,}/i,
  "private key block" => /-{5}BEGIN [A-Z ]*PRIVATE KE[Y]-{5}/,
  "GitHub token" => /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})\b/,
  "Slack token" => /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
  "JWT" => /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\./,
  "ARN carrying an account id" => /arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:/,
  "privileged PR-target trigger" => /pull_request_targe[t]/,
}
account_id = /(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])/

files = `git ls-files -z`.split("\0")
files.each do |f|
  next unless File.file?(f)
  data = File.binread(f)
  next if data.include?("\0")
  data = data.force_encoding("UTF-8").scrub
  text_rules.each { |name, re| fail_.("#{f}: #{name}") if data =~ re }
  fail_.("#{f}: 12-digit number that looks like an account id") if data =~ account_id
end

# Workflow structure: which files may hold an id-token grant and how they may be triggered.
oidc_files = %w[deploy.yml e2e.yml promote.yml]
find_key = lambda do |node, key|
  case node
  when Hash then node.any? { |k, v| k == key || find_key.(v, key) }
  when Array then node.any? { |v| find_key.(v, key) }
  else false
  end
end
Dir[".github/workflows/*.{yml,yaml}"].sort.each do |f|
  base = File.basename(f)
  doc = YAML.safe_load(File.read(f), aliases: false)
  on = doc["on"] || doc[true] || {}
  on = { on => nil } if on.is_a?(String)
  on = on.to_h { |k| [k, nil] } if on.is_a?(Array)
  if find_key.(doc, "id-token") && !oidc_files.include?(base)
    fail_.("#{f}: an id-token permission is only allowed in #{oidc_files.join(', ')}")
  end
  if find_key.(doc, "environment") && !oidc_files.include?(base)
    fail_.("#{f}: only #{oidc_files.join(', ')} may use a deployment environment")
  end
  if on.key?("pull_request") && (find_key.(doc, "id-token") || find_key.(doc, "environment"))
    fail_.("#{f}: a workflow with id-token or an environment must not run on pull_request")
  end
  next unless oidc_files.include?(base)
  extra = on.keys - %w[workflow_call workflow_dispatch push]
  fail_.("#{f}: triggers #{extra.inspect} are not allowed in a workflow that can use id-token") unless extra.empty?
  if on.key?("push") && (on["push"] || {}).fetch("branches", nil) != ["main"]
    fail_.("#{f}: push must be limited to branches: [main]")
  end
  (doc["jobs"] || {}).each do |jn, job|
    next if job.key?("uses") # a reusable-workflow call; the called file is checked on its own
    next unless find_key.(job, "id-token")
    fail_.("#{f}: job #{jn} grants id-token without an environment") unless job["environment"]
    fail_.("#{f}: job #{jn} grants id-token but is not restricted to refs/heads/main") unless job["if"].to_s.include?("refs/heads/main")
  end
end

exit(bad.zero? ? 0 : 1)
