import { Stack, RemovalPolicy, Token } from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';
import { REGION, StageConfig, deleteAllowedRoleNames, isDisposable } from './config';

export function assertRegion(stack: Stack): void {
  if (!Token.isUnresolved(stack.region) && stack.region !== REGION) {
    throw new Error(`stacks must be deployed to ${REGION}; got ${stack.region}`);
  }
}

export const removalPolicyFor = (c: StageConfig): RemovalPolicy =>
  isDisposable(c.stage) ? RemovalPolicy.DESTROY : RemovalPolicy.RETAIN;

export function lookupZone(scope: Construct, c: StageConfig): route53.IHostedZone {
  if (c.hostedZoneId) {
    return route53.HostedZone.fromHostedZoneAttributes(scope, 'Zone', {
      hostedZoneId: c.hostedZoneId,
      zoneName: c.hostedZoneName,
    });
  }
  return route53.HostedZone.fromLookup(scope, 'Zone', { domainName: c.hostedZoneName });
}

/** ARNs of the roles allowed to delete data on this stage (the roles themselves are created elsewhere). */
export function deleteAllowedRoleArns(stack: Stack, c: StageConfig): string[] {
  return deleteAllowedRoleNames(c.stage).map((n) => `arn:aws:iam::${stack.account}:role/${n}`);
}

/** Deny everyone except the named roles. */
export const notNamedRoles = (arns: string[]): Record<string, Record<string, string[]>> => ({
  ArnNotLike: { 'aws:PrincipalArn': arns },
});

export const anyone = () => new iam.AnyPrincipal();
