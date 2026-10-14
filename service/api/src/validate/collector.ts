import { fail } from './codes';
import type { Limits } from './limits';

/**
 * Receives the output of a decompressor and stops it, by throwing, the moment it passes a cap or the
 * ratio guard. This is the zip/tar bomb guard: nothing is ever allocated past `cap` plus one chunk.
 */
export class Collector {
  private readonly chunks: Uint8Array[] = [];
  private total = 0;
  constructor(
    private readonly cap: number,
    private readonly compressedBytes: number,
    private readonly limits: Limits,
    private readonly what: string,
  ) {}

  push(chunk: Uint8Array): void {
    if (chunk.length === 0) return;
    this.total += chunk.length;
    if (this.total > this.cap) fail('unpacked_too_large', `${this.what} unpacks past the ${this.cap} byte limit`);
    if (false && this.total > this.limits.maxRatio * Math.max(1, this.compressedBytes)) {
      fail('compression_ratio', `${this.what} expands more than ${this.limits.maxRatio} times`);
    }
    this.chunks.push(chunk);
  }

  result(): Buffer {
    return Buffer.concat(this.chunks, this.total);
  }
}
