import { decodeMirror, MIRROR_KEY, MIRROR_MAX_AGE_MS } from '../validate/native-mirror';
import type { NativeMirror } from '../validate/native-mirror';
import type { ObjectStore } from './ports';

export interface MirrorReaderOptions {
  now?: () => Date;
  /** The most a read may take; a mirror that does not arrive in time is a mirror that is missing. */
  timeoutMs?: number;
  maxAgeMs?: number;
  log?: (line: Record<string, unknown>) => void;
}

/** A read of the mirror must fit well inside the validator's own budget (VALIDATOR_TIMEOUT_SECONDS); it is about 155 kB. */
export const MIRROR_READ_TIMEOUT_MS = 5000;

/**
 * Reads the conda-forge name mirror for a Lambda container: lazily, on the first publish, and again only when the copy it holds is
 * older than the staleness limit (a container can outlive a day). It never throws and never blocks past `timeoutMs`: an object that
 * is missing, unreadable or malformed, or a read that is too slow, answers `undefined` (or the older copy it still holds), and the
 * validator then warns. A failed read is not remembered, so the next publish tries again.
 */
export class MirrorReader {
  private held: NativeMirror | undefined;
  private readonly now: () => Date;
  private readonly timeoutMs: number;
  private readonly maxAgeMs: number;
  private readonly log: (line: Record<string, unknown>) => void;

  constructor(
    private readonly store: Pick<ObjectStore, 'get'>,
    o: MirrorReaderOptions = {},
  ) {
    this.now = o.now ?? (() => new Date());
    this.timeoutMs = o.timeoutMs ?? MIRROR_READ_TIMEOUT_MS;
    this.maxAgeMs = o.maxAgeMs ?? MIRROR_MAX_AGE_MS;
    this.log = o.log ?? ((l) => console.log(JSON.stringify(l)));
  }

  async read(): Promise<NativeMirror | undefined> {
    if (this.held && this.now().getTime() - this.held.generatedAt.getTime() <= this.maxAgeMs) return this.held;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`no answer in ${this.timeoutMs} ms`)), this.timeoutMs);
      });
      const bytes = await Promise.race([this.store.get(MIRROR_KEY), timeout]);
      if (bytes === undefined) {
        this.log({ level: 'warn', msg: 'the conda-forge name mirror is not in the bucket', key: MIRROR_KEY });
      } else {
        this.held = decodeMirror(bytes);
      }
    } catch (err) {
      this.log({ level: 'warn', msg: 'the conda-forge name mirror could not be read', key: MIRROR_KEY, error: String(err) });
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
    return this.held;
  }
}
