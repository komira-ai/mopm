import { S3Channel } from './aws';
import { runNativeMirrorJob } from './native-mirror-job';
import { regionOf, required } from './wiring';

/**
 * EventBridge schedule -> the conda-forge name mirror job. A failure is thrown so that the invocation is recorded as failed (the
 * Lambda's error metric has an alarm); the previous mirror stays in the bucket and ages into the validators' "stale" warning.
 */
export const handler = async (): Promise<void> => {
  const env = process.env;
  await runNativeMirrorJob({ objects: new S3Channel(required(env, 'MOPM_CHANNEL_BUCKET'), { region: regionOf(env) }) });
};
