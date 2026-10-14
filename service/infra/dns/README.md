# DNS: Route 53 zones for mopm.dev

`mopm.dev` is registered at GoDaddy. Its DNS is served by Route 53, one public hosted zone per stage account:

| stage | zone | account |
|---|---|---|
| prod | `mopm.dev` | prod |
| beta | `beta.mopm.dev` | beta |
| gamma | `gamma.mopm.dev` | gamma |

The service stacks (`service/infra/stacks`) look up the zone of their stage by name in their own account, so
these zones must exist before any service stack deploys. Beta and gamma are delegated from the prod zone with NS
records; no cross-account roles are involved, the admin copies four host names from one account to another.

This is run once by a human admin with their own credentials, never from CI. Account ids are flags to the
script and are not committed. The stacks use the legacy CDK synthesizer, so no `cdk bootstrap` is needed first.
Zones are retained if a stack is deleted (a new zone would get new name servers and break the delegation).

## Order

Preview any command first: `dns.sh` prints what it would run and executes nothing without `--apply`.

1. **Zone in prod** (creates `mopm.dev` and prints its four name servers):
   ```sh
   service/infra/dns/dns.sh --stage prod --account <prod id> --profile <prod profile>
   service/infra/dns/dns.sh --stage prod --account <prod id> --profile <prod profile> --apply
   ```
2. **GoDaddy**: Domain > DNS > Nameservers > "I'll use my own nameservers" > enter the four Route 53 name
   servers printed in step 1 (no trailing dots) > Save. GoDaddy currently holds only parking A records and no
   MX or TXT records, so nothing needs to be copied into Route 53 first. Changes can take up to 48 hours to
   propagate; check with `dig +short NS mopm.dev` (it must list the four Route 53 hosts) before relying on it.
3. **Zones in beta and gamma** (each prints its four name servers; keep them):
   ```sh
   service/infra/dns/dns.sh --stage beta  --account <beta id>  --profile <beta profile>  --apply
   service/infra/dns/dns.sh --stage gamma --account <gamma id> --profile <gamma profile> --apply
   ```
4. **Delegate from prod** (NS records for `beta.mopm.dev` and `gamma.mopm.dev` in the `mopm.dev` zone, from the
   name servers of step 3, comma separated):
   ```sh
   service/infra/dns/dns.sh --stage prod --delegate --account <prod id> --profile <prod profile> \
     --beta-ns ns-a,ns-b,ns-c,ns-d --gamma-ns ns-e,ns-f,ns-g,ns-h --apply
   ```
5. **Verify**:
   ```sh
   dig +short NS mopm.dev
   dig +short NS beta.mopm.dev      # the beta zone's four name servers
   dig +short NS gamma.mopm.dev     # the gamma zone's four name servers
   dig +short NS beta.mopm.dev @<one of the mopm.dev name servers>   # answers straight from prod, no cache
   ```
   Then continue with `service/infra/access/BOOTSTRAP.md`.

## Notes

- `.dev` is on the browser HSTS preload list: browsers only speak HTTPS to `mopm.dev` and every subdomain.
  That is what the service wants (CloudFront and API Gateway with ACM certificates); there is no HTTP fallback.
- Cost: Route 53 charges $0.50 per hosted zone per month (three zones, $1.50) plus a small per-query fee.
- If you re-create a zone, its name servers change; redo steps 2 or 4 for it.
- `--delegate` is refused for any stage but prod, and the delegation stack contains only NS records for the
  two child names; `dns.sh --help` lists every flag. Tests: `npm ci && npm test` here (CI job `dns`).
