import { CfnOutput, Fn, LegacyStackSynthesizer, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib';
import { PublicHostedZone } from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';
import { Stage, zoneName, zoneStackName } from './config';

/** The public hosted zone of one stage, and nothing else. Prod owns mopm.dev; beta and gamma own their subdomain. */
export class ZoneStack extends Stack {
  readonly zone: PublicHostedZone;

  constructor(scope: Construct, readonly stage: Stage, props: StackProps) {
    // The legacy synthesizer needs no CDK bootstrap: the admin deploys this before any other bootstrap step,
    // with their own credentials. The template is tiny and has no assets.
    super(scope, zoneStackName(stage), { ...props, synthesizer: new LegacyStackSynthesizer() });
    this.zone = new PublicHostedZone(this, 'Zone', { zoneName: zoneName(stage), comment: `mopm ${stage} public zone` });
    // Deleting a zone changes its name servers, which breaks the delegation above it. Keep it if the stack goes.
    this.zone.applyRemovalPolicy(RemovalPolicy.RETAIN);
    new CfnOutput(this, 'NameServers', {
      description: 'The four name servers of this zone, comma separated',
      value: Fn.join(',', this.zone.hostedZoneNameServers!),
    });
    new CfnOutput(this, 'ZoneName', { value: this.zone.zoneName });
  }
}
