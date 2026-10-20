// The docs pages are listed in four places besides DOC_PAGES (src/links.ts): promote.yml's path filter (a docs-only push
// must deploy), service-ci.yml's page loop, tools/check-dist.ts (derived) and check_dist.js. Each is compared with
// DOC_PAGES in both directions, so adding or dropping a page in one place and not the others goes red.
import { readFileSync } from 'fs';
import { join } from 'path';
import { DOC_PAGES } from '../src/links';
import { REQUIRED } from '../tools/check-dist';
import { REPO_ROOT } from './build-fixture';

const read = (p: string) => readFileSync(join(REPO_ROOT, p), 'utf8');
const sorted = (a: string[]) => [...a].sort();

test('promote.yml triggers on exactly the doc sources the site renders', () => {
  const yml = read('.github/workflows/promote.yml');
  const paths = [...yml.slice(yml.indexOf('paths:'), yml.indexOf('workflow_dispatch:')).matchAll(/^\s*- '([^']+)'/gm)].map((m) => m[1]);
  const docs = paths.filter((p) => p.endsWith('.md'));
  expect(sorted(docs)).toEqual(sorted(DOC_PAGES.map((d) => d.source)));
});

test('service-ci.yml checks exactly the pages the build writes', () => {
  const line = read('.github/workflows/service-ci.yml')
    .split('\n')
    .find((l) => l.includes('docs/index.html') && l.includes('for f in'));
  if (!line) throw new Error('no page loop in service-ci.yml');
  const files = line.slice(line.indexOf(' in ') + 4, line.indexOf(';')).trim().split(/\s+/);
  expect(sorted(files)).toEqual(sorted(REQUIRED));
});

test('check_dist.js lists the pages of tools/check-dist.ts, less the installer', () => {
  const js = read('site/check_dist.js');
  const m = /PAGES = \[([^\]]*)\]/.exec(js);
  if (!m) throw new Error('no PAGES in check_dist.js');
  const pages = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  expect(sorted(pages)).toEqual(sorted(REQUIRED.filter((p) => p !== 'install.sh')));
});
