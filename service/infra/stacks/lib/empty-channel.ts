import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

/** The four subdirs every channel always has (spec/channel.md, Layout). */
export const CHANNEL_SUBDIRS = ['noarch', 'linux-64', 'linux-aarch64', 'osx-arm64'] as const;

/** Conda repodata of a subdir with no packages. Keys sorted, no timestamps, like the registry's writer. */
export function emptyRepodata(subdir: string): string {
  return (
    JSON.stringify({
      info: { subdir },
      packages: {},
      'packages.conda': {},
      removed: [],
      repodata_version: 1,
    }) + '\n'
  );
}

/**
 * A valid zstd frame holding `data` in one raw (uncompressed) block. Every zstd decoder accepts it, and it needs
 * no compression library. Single-segment frame, 1-byte content size, so `data` must be under 256 bytes.
 */
export function zstdRawFrame(data: Buffer): Buffer {
  if (data.length > 255) throw new Error('zstdRawFrame: input too large for the 1-byte content size');
  const header = (data.length << 3) | 1; // last block, type raw (0), block size
  return Buffer.concat([
    Buffer.from([0x28, 0xb5, 0x2f, 0xfd, 0x20, data.length]),
    Buffer.from([header & 0xff, (header >> 8) & 0xff, (header >> 16) & 0xff]),
    data,
  ]);
}

/** Throws unless `json` is the conda empty repodata of exactly `subdir`. */
export function assertEmptyRepodata(subdir: string, json: string): void {
  const r = JSON.parse(json);
  const isEmptyObj = (v: unknown) => typeof v === 'object' && v !== null && !Array.isArray(v) && Object.keys(v).length === 0;
  if (r?.info?.subdir !== subdir) throw new Error(`repodata for ${subdir} has info.subdir ${JSON.stringify(r?.info?.subdir)}`);
  if (!isEmptyObj(r.packages)) throw new Error(`repodata for ${subdir}: packages must be an empty object`);
  if (!isEmptyObj(r['packages.conda'])) throw new Error(`repodata for ${subdir}: packages.conda must be an empty object`);
}

/** Writes <subdir>/repodata.json and <subdir>/repodata.json.zst for every subdir; returns the directory. */
export function writeEmptyChannel(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mopm-empty-channel-'));
  for (const s of CHANNEL_SUBDIRS) {
    const json = emptyRepodata(s);
    assertEmptyRepodata(s, json);
    fs.mkdirSync(path.join(dir, s));
    fs.writeFileSync(path.join(dir, s, 'repodata.json'), json);
    fs.writeFileSync(path.join(dir, s, 'repodata.json.zst'), zstdRawFrame(Buffer.from(json)));
  }
  return dir;
}
