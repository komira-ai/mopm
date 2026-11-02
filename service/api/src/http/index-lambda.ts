import { S3Channel } from '../publish/aws';
import { readIndex, type IndexObjects } from './index-reader';

/** The part of an API Gateway HTTP API (payload format 2.0) event the reader needs. */
interface GatewayEvent {
  rawPath: string;
  requestContext: { requestId: string; http: { method: string } };
}

let objects: IndexObjects | undefined;

/** `GET /index/{proxy+}`: the files under `index/` of the channel bucket. The role may read nothing else. */
export const handler = async (event: GatewayEvent) => {
  objects ??= (() => {
    const bucket = process.env.MOPM_CHANNEL_BUCKET;
    if (!bucket) throw new Error('MOPM_CHANNEL_BUCKET is not set');
    const s3 = new S3Channel(bucket, { region: process.env.AWS_REGION ?? 'us-east-1' });
    return { get: (key: string) => s3.getExact(key) };
  })();
  return readIndex(objects, { method: event.requestContext.http.method, path: event.rawPath }, event.requestContext.requestId);
};
