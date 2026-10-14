import { Duration, LegacyStackSynthesizer, Stack, StackProps } from 'aws-cdk-lib';
import { HostedZone, NsRecord } from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';
import { CHILD_STAGES, ChildStage, DELEGATION_STACK_NAME, ROOT_ZONE, zoneName } from './config';

/** Name servers of each child zone, taken from the child stacks' outputs by the admin. */
export type ChildNameServers = Record<ChildStage, string[]>;

/**
 * Deployed in the PROD account only. Adds one NS record set per child stage to the mopm.dev zone, so that
 * beta.mopm.dev and gamma.mopm.dev resolve through the zones in their own accounts. No cross-account roles:
 * the child name servers are plain values the admin passes in.
 */
export class DelegationStack extends Stack {
  /** `hostedZoneId` is for synth tests only: it skips the lookup of the mopm.dev zone in the prod account. */
  constructor(scope: Construct, children: ChildNameServers, props: StackProps, hostedZoneId?: string) {
    super(scope, DELEGATION_STACK_NAME, { ...props, synthesizer: new LegacyStackSynthesizer() });
    // Looked up by name, so this stack does not depend on the zone stack's exports.
    const parentZone = hostedZoneId
      ? HostedZone.fromHostedZoneAttributes(this, 'Parent', { hostedZoneId, zoneName: ROOT_ZONE })
      : HostedZone.fromLookup(this, 'Parent', { domainName: ROOT_ZONE, privateZone: false });
    for (const stage of CHILD_STAGES) {
      new NsRecord(this, `Delegate-${stage}`, {
        zone: parentZone,
        recordName: zoneName(stage),
        values: children[stage],
        ttl: Duration.hours(1),
        comment: `delegates ${zoneName(stage)} to the ${stage} account`,
      });
    }
  }
}
