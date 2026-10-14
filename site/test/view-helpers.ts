// Test helpers for views: render a View through StringDoc and check the markup it holds.
import { type SNode, serialize, StringDoc, TAGS } from '../src/doc';
import { decodePackageInfo, decodeVersionDetail } from '../src/decode';
import type { PackageInfo, VersionDetail } from '../src/types';
import type { View } from '../src/views/common';
import { tagsIn } from '../tools/check-dist';
import { validReadCases } from './fixtures';

export const sdoc = new StringDoc();

const ALLOWED = new Set<string>(TAGS);

/** The view's nodes as HTML, after checking that every tag is in the Doc allowlist and nothing is inline code. */
export function html(view: View<SNode>): string {
  const out = serialize(view.nodes);
  for (const [tag, attrs] of tagsIn(out)) {
    if (!ALLOWED.has(tag)) throw new Error(`<${tag}> is outside the Doc allowlist`);
    for (const [k] of attrs) if (k === 'style' || k.startsWith('on')) throw new Error(`<${tag} ${k}> in a view`);
  }
  return out;
}

/** The text of the HTML with tags removed and the serializer's escapes undone. */
export function text(s: string): string {
  return s
    .replace(/<[^>]*>/g, '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');
}

/** Every href in the HTML. */
export function hrefs(s: string): string[] {
  return tagsIn(s).flatMap(([, attrs]) => attrs.filter(([k]) => k === 'href').map(([, v]) => v.replace(/&amp;/g, '&')));
}

function fixture(name: string): unknown {
  const c = validReadCases().find((x) => x.name === name);
  if (!c) throw new Error(`no fixture '${name}'`);
  return JSON.parse(JSON.stringify(c.response.body));
}

/** A decoded fixture answer, with fields changed (applied to the raw body before decoding). */
export function packageFixture(change: (raw: Record<string, unknown>) => void = () => undefined): PackageInfo {
  const raw = fixture('package info') as Record<string, unknown>;
  change(raw);
  return decodePackageInfo(raw);
}

export function versionFixture(
  name: 'version detail' | 'yanked version keeps its files and says why' | 'tombstoned version has no url',
  change: (raw: Record<string, unknown>) => void = () => undefined,
): VersionDetail {
  const raw = fixture(name) as Record<string, unknown>;
  change(raw);
  return decodeVersionDetail(raw);
}
