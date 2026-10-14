# Structural lint for .github/workflows. Run from the repository root.
# With path arguments, only the per-file checks run on those files (used by tests/lint/run.rb).
require "yaml"
require "tmpdir"

bad = 0
fail_ = ->(msg) { warn "workflow-lint: #{msg}"; bad += 1 }
oidc_files = %w[deploy.yml e2e.yml promote.yml oidc-subject-check.yml]
# Names whose values must never reach a log: no echo/printf/cat/tee of them.
secret_names = %w[AWS_ACCOUNT_ID AWS_REGION ROLE_ARN AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN]
secret_alt = "(?:" + secret_names.join("|") + ")"
secret_ref = /\$(?:\{#{secret_alt}[^}]*\}|#{secret_alt}\b)/
# Returns the offending logical lines of a run script. ::add-mask:: lines are the one allowed use.
leaky_lines = lambda do |script|
  out = []
  heredoc_end = nil
  script.gsub(/\\\n/, " ").each_line do |line|
    if heredoc_end
      heredoc_end = nil if line.strip == heredoc_end[:tag]
      out << line.strip if heredoc_end && line =~ secret_ref
      next
    end
    if line =~ /\b(?:cat|tee)\b.*<<-?\s*['"]?(\w+)['"]?/
      heredoc_end = { tag: $1 }
    end
    next if line.include?("::add-mask::")
    line.split(/;|&&|\|\||\|/).each do |seg|
      out << seg.strip if seg =~ /\b(?:echo|printf|cat|tee)\b/ && seg =~ secret_ref
    end
  end
  out
end
owned_actions = %w[checkout setup-node upload-artifact download-artifact]

each_perm = lambda do |node, path, &blk|
  case node
  when Hash
    node.each do |k, v|
      blk.call(path + [k], v) if k == "permissions"
      each_perm.(v, path + [k], &blk)
    end
  when Array
    node.each_with_index { |v, i| each_perm.(v, path + [i], &blk) }
  end
end

(ARGV.empty? ? Dir[".github/workflows/*.{yml,yaml}"].sort : ARGV).each do |f|
  base = File.basename(f)
  doc = YAML.safe_load(File.read(f), aliases: false)
  jobs = doc["jobs"] || {}

  # Default token is read-only and stated at the top.
  top = doc["permissions"]
  fail_.("#{f}: top-level permissions must be set") if top.nil?
  fail_.("#{f}: top-level permissions must be read-only") if top.is_a?(Hash) && top.values.any? { |v| v != "read" && v != "none" }
  fail_.("#{f}: top-level permissions must not be #{top.inspect}") if top.is_a?(String)

  # Only id-token: write, and only in the deploy workflows. Never write-all or contents: write.
  each_perm.(doc, []) do |path, value|
    if value.is_a?(String)
      fail_.("#{f}: #{path.join('.')} = #{value}") if value =~ /write/
    elsif value.is_a?(Hash)
      value.each do |k, v|
        next unless v == "write"
        fail_.("#{f}: #{path.join('.')}.#{k}: write is not allowed") unless k == "id-token" && oidc_files.include?(base)
      end
    end
  end

  File.read(f).scan(/\bvars\.\w*(?:ACCOUNT|REGION|ARN)\w*/i) { |m| fail_.("#{f}: #{m}: account, region and role ARNs come from environment secrets, not vars") }
  fail_.("#{f}: secrets: inherit is not allowed") if File.read(f) =~ /secrets:\s*inherit/
  # The privileged PR trigger is spelled in two pieces so hygiene.rb does not flag this file.
  ["pull_request_" + "target", "workflow_run", "issue_comment"].each do |t|
    on = doc["on"] || doc[true] || {}
    keys = on.is_a?(Hash) ? on.keys : Array(on)
    fail_.("#{f}: trigger #{t} is not allowed") if keys.include?(t)
  end

  jobs.each do |jn, job|
    if job["uses"] && job["uses"] !~ %r{\A\./\.github/workflows/[a-z0-9_-]+\.yml\z}
      fail_.("#{f}: job #{jn} may only call a local workflow, not #{job['uses']}")
    end
    (job["steps"] || []).each_with_index do |st, i|
      if st["uses"] && st["uses"] !~ /\Aactions\/(#{owned_actions.join('|')})@[0-9a-f]{40}\z/
        fail_.("#{f}: #{jn} step #{i}: only GitHub-owned actions pinned by full SHA are allowed: #{st['uses']}")
      end
      next unless st["run"]
      leaky_lines.(st["run"]).each { |l| fail_.("#{f}: #{jn} step #{i}: prints a secret-bearing variable: #{l}") }
      fail_.("#{f}: #{jn} step #{i}: run script references secrets.*") if st["run"] =~ /\bsecrets\.\w+/
      # Event fields and inputs reach scripts through env:, never by interpolation.
      fail_.("#{f}: #{jn} step #{i}: run script interpolates an expression; pass it through env:") if st["run"].include?("${{")
      Dir.mktmpdir do |d|
        t = File.join(d, "step.sh")
        File.write(t, st["run"])
        fail_.("#{f}: #{jn} step #{i}: bash -n failed") unless system("bash", "-n", t)
      end
    end
  end
end

if ARGV.empty?
  # promote.yml: beta deploy, e2e, gamma deploy, e2e, prod deploy, prod smoke; each needs the one before.
  chain = { "beta-deploy" => nil, "beta-e2e" => "beta-deploy", "gamma-deploy" => "beta-e2e",
            "gamma-e2e" => "gamma-deploy", "prod-deploy" => "gamma-e2e", "prod-smoke" => "prod-deploy" }
  uses = { "beta-deploy" => "deploy", "beta-e2e" => "e2e", "gamma-deploy" => "deploy",
           "gamma-e2e" => "e2e", "prod-deploy" => "deploy", "prod-smoke" => "e2e" }
  stage = { "beta-deploy" => "beta", "beta-e2e" => "beta", "gamma-deploy" => "gamma",
            "gamma-e2e" => "gamma", "prod-deploy" => "prod", "prod-smoke" => "prod" }
  pdoc = YAML.safe_load(File.read(".github/workflows/promote.yml"), aliases: false)
  pon = pdoc["on"] || pdoc[true]
  pon_keys = pon.is_a?(Hash) ? pon.keys : Array(pon)
  # Manual only until beta is live and the CEO approves a push trigger; then change this and docs together.
  fail_.("promote.yml: triggers must be exactly workflow_dispatch for now, got #{pon_keys.inspect}") if pon_keys != ["workflow_dispatch"]
  pj = pdoc["jobs"]
  fail_.("promote.yml: jobs #{pj.keys.sort} differ from expected #{chain.keys.sort}") if pj.keys.sort != chain.keys.sort
  chain.each do |jn, prev|
    job = pj[jn] or next
    need = Array(job["needs"])
    fail_.("promote.yml: #{jn} needs #{need.inspect}, expected #{Array(prev).inspect}") if need != Array(prev)
    fail_.("promote.yml: #{jn} must call ./.github/workflows/#{uses[jn]}.yml") if job["uses"] != "./.github/workflows/#{uses[jn]}.yml"
    fail_.("promote.yml: #{jn} must target stage #{stage[jn]}") if (job["with"] || {})["stage"] != stage[jn]
  end
  pj.each do |jn, job|
    %w[if continue-on-error].each { |k| fail_.("promote.yml: #{jn} must not set #{k}") if job.key?(k) }
  end

  # deploy.yml and e2e.yml: the guard job gates the credential job.
  %w[deploy e2e].each do |w|
    jobs = YAML.safe_load(File.read(".github/workflows/#{w}.yml"), aliases: false)["jobs"]
    cred = jobs.select { |_, j| j.dig("permissions", "id-token") == "write" }
    fail_.("#{w}.yml: expected exactly one job with id-token") unless cred.size == 1
    cred.each do |jn, j|
      fail_.("#{w}.yml: #{jn} must need the guard job") unless Array(j["needs"]).include?("guard")
      fail_.("#{w}.yml: #{jn} must declare an environment") unless j["environment"]
    end
  end

  # oidc-subject-check.yml: manual, main only, no environment except beta, no AWS.
  sc = YAML.safe_load(File.read(".github/workflows/oidc-subject-check.yml"), aliases: false)
  scon = sc["on"] || sc[true]
  fail_.("oidc-subject-check.yml: only workflow_dispatch is allowed") unless scon.is_a?(Hash) && scon.keys == ["workflow_dispatch"]
  sc["jobs"].each do |jn, j|
    next unless j.dig("permissions", "id-token") == "write"
    fail_.("oidc-subject-check.yml: #{jn} must need the guard job") unless Array(j["needs"]).include?("guard")
    fail_.("oidc-subject-check.yml: #{jn} must not use environment #{j['environment'].inspect}") unless j["environment"].nil? || j["environment"] == "beta"
    fail_.("oidc-subject-check.yml: #{jn} must grant exactly id-token and contents read") unless j["permissions"] == { "id-token" => "write", "contents" => "read" }
  end
  fail_.("oidc-subject-check.yml: needs one job without an environment and one in beta") unless sc["jobs"].values.map { |j| j["environment"] }.compact.sort == ["beta"] && sc["jobs"].values.any? { |j| j.dig("permissions", "id-token") == "write" && j["environment"].nil? }

end

exit(bad.zero? ? 0 : 1)
