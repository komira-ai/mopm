// T12: link rewriting. In a repo doc, a relative link resolves in the repo as GitHub resolves it: the published docs
// stay on the site, any other repo path goes to GitHub, and anything resolving outside the repo is text. Schemes are
// matched case-insensitively. In a readme, only absolute links and in-page fragments survive.
import { internalHref, safeHref } from '../src/links';

const blob = (p: string) => `https://github.com/komira-ai/mopm/blob/main/${p}`;
const docs = (source: string) => ({ mode: 'docs', idPrefix: '', source }) as const;
const readme = { mode: 'readme', idPrefix: 'readme-' } as const;

test.each([
  ['spec/mopm-toml.md', 'mopm-toml.md', '/docs/mopm-toml/'],
  ['spec/mopm-toml.md', 'mopm-toml.md#rules', '/docs/mopm-toml/#rules'],
  ['spec/mopm-toml.md', './mopm-toml.md', '/docs/mopm-toml/'],
  ['spec/mopm-toml.md', '../docs/mopm-test.md', '/docs/mopm-test/'],
  ['spec/mopm-toml.md', '/docs/mopm-test.md', '/docs/mopm-test/'],
  ['spec/mopm-toml.md', '/spec/mopm-toml.md#sections', '/docs/mopm-toml/#sections'],
  ['spec/mopm-toml.md', 'channel.md', blob('spec/channel.md')],
  ['spec/mopm-toml.md', 'api/openapi.yaml', blob('spec/api/openapi.yaml')],
  ['spec/mopm-toml.md', '../README.md#goals', blob('README.md#goals')],
  ['spec/mopm-toml.md', '/LICENSE', blob('LICENSE')],
  ['spec/mopm-toml.md', '../../x', null],
  ['spec/mopm-toml.md', '//github.com/komira-ai/mopm', null],
  ['spec/mopm-toml.md', '#sections', '#sections'],
  ['spec/mopm-toml.md', 'HTTPS://github.com/komira-ai/mopm', 'https://github.com/komira-ai/mopm'],
  ['spec/mopm-toml.md', 'Mailto:a@mopm.dev', 'mailto:a@mopm.dev'],
  ['spec/mopm-toml.md', 'JavaScript:alert(1)', null],
  ['docs/mopm-test.md', 'mopm-test.md', '/docs/mopm-test/'],
  ['docs/mopm-test.md', '../spec/mopm-toml.md', '/docs/mopm-toml/'],
  ['docs/mopm-test.md', '../src/cli/test_cmd.zig', blob('src/cli/test_cmd.zig')],
  // As on GitHub, a bare name resolves next to the doc (there is no docs/mopm-toml.md, so GitHub shows a 404 too).
  ['docs/mopm-test.md', 'mopm-toml.md', blob('docs/mopm-toml.md')],
] as const)('in %s, %j -> %j', (source, raw, want) => {
  expect(safeHref(raw, docs(source))).toBe(want);
});

test.each([
  ['relative.md', null],
  ['/abs/path', null],
  ['#Install', '#readme-Install'],
  ['#caf%C3%A9', '#readme-caf%C3%A9'],
  ['#', null],
  ['HTTPS://mopm.dev/x', 'https://mopm.dev/x'],
] as const)('in a readme, %j -> %j', (raw, want) => {
  expect(safeHref(raw, readme)).toBe(want);
});

test('internalHref accepts same-site paths only', () => {
  expect(internalHref('/packages/ab')).toBe('/packages/ab');
  for (const bad of ['//evil', '/\\evil', 'https://mopm.dev', 'packages/ab', '/\t/evil', '']) {
    expect(() => internalHref(bad)).toThrow();
  }
});
