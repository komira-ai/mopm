#!/usr/bin/env node
// Usage: cdk synth|deploy -c stage=beta|gamma|prod [-c version=<release>] [-c commit=<git sha>] [-c rustZipDir=<dir of the Rust functions' zips>] [-c hostedZoneId=<dummy, synth only>]
// The account comes from the CDK environment (CDK_DEFAULT_ACCOUNT) at deploy time; it is never in a file.
import { App } from 'aws-cdk-lib';
import { stageStacksFromContext } from '../lib/app';

stageStacksFromContext(new App(), { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION });
