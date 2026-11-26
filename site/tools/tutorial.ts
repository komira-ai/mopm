// The tutorial's pages, prerendered from the lessons (tools/lessons.ts): /tutorial, the lessons in order, and
// /tutorial/<lesson>, a lesson's text rendered by the same restricted Markdown renderer as the docs (raw HTML stays
// text, every link is checked), its title and its place in the tutorial, and the mount point, #lesson-runner
// (data-lesson="<lesson>"), holding the lesson's editable files and its commands (src/tutorial/view.ts lessonSource).
// The tutorial's page script (src/tutorial/main.ts, the bundle a lesson's page loads after main.js) reads the lesson
// from there and replaces it with the sign-in card or the editor and the Run button. Nothing on them needs a session:
// the pages work without scripts and without signing in (the files and commands are on the page to read), and the
// header is every page's (no login, no "Sign out").
//
// The build writes them to dist/tutorial/ (tools/build.ts). The edge router serves `/tutorial` and `/tutorial/<lesson>`
// from them (src/routes.ts TUTORIAL_PATH, LESSON), on a stage the site stack ships them to: one whose configuration
// names the tutorial's E2B template (service/infra/stacks/lib/site-stack.ts, servesTutorial).

import { h, type SElement, type SNode } from '../src/doc';
import { internalHref } from '../src/links';
import { renderMarkdown } from '../src/markdown/render';
import { TUTORIAL_PATH } from '../src/routes';
import { lessonSource, RUNNER_ID } from '../src/tutorial/view';
import { doc, type PageSpec } from './layout';
import type { Lesson } from './lessons';

/** The prefix of every heading id and in-page link of a lesson's text, so none can take an id the page uses. */
export const LESSON_ID_PREFIX = 'lesson-';
/** The id of the element the tutorial's page script fills with the editor, the buttons and the output. */
export { RUNNER_ID };

/** The routes of the tutorial's pages (src/routes.ts). */
export { TUTORIAL_PATH };
export const lessonPath = (l: Pick<Lesson, 'id'>): string => `${TUTORIAL_PATH}/${l.id}`;

/** The lesson's text as an article: lesson.md under the page's h1 (its headings shifted down one level). */
export function lessonArticle(l: Lesson): { node: SElement; fallbacks: number } {
  const article = h(doc, 'article', { class: 'prose lesson' }) as SElement;
  const fallbacks = renderMarkdown(doc, article, l.markdown, {
    idPrefix: LESSON_ID_PREFIX,
    headingShift: 1,
    links: { mode: 'docs', source: l.source },
    docs: {},
  });
  return { node: article, fallbacks };
}

function crumb(title: string): SNode {
  return h(
    doc,
    'nav',
    { class: 'crumb', 'aria-label': 'Breadcrumb' },
    h(doc, 'a', { href: internalHref(TUTORIAL_PATH) }, 'Tutorial'),
    h(doc, 'span', { class: 'sep', 'aria-hidden': 'true' }, '/'),
    h(doc, 'span', { 'aria-current': 'page' }, title),
  );
}

/** The page of the lesson at `position` (from 1) of `count`, the lessons in order. */
export function lessonPage(l: Lesson, position: number, count: number): PageSpec {
  return {
    title: `${l.title} (tutorial)`,
    description: l.summary,
    kind: 'tutorial',
    path: lessonPath(l),
    main: [
      crumb(l.title),
      h(doc, 'p', { class: 'lesson-place muted small' }, `Lesson ${position} of ${count}`),
      h(doc, 'h1', null, l.title),
      lessonArticle(l).node,
      h(
        doc,
        'section',
        { id: RUNNER_ID, class: 'lesson-runner', 'aria-label': 'Try it', 'data-lesson': l.id },
        ...lessonSource(doc, { id: l.id, files: l.files, actions: l.actions }),
      ),
    ],
    tutorialScript: true,
  };
}

/** /tutorial: every lesson in order, each its title (a link to its page) and its summary. */
export function tutorialIndexPage(lessons: readonly Lesson[]): PageSpec {
  return {
    title: 'Tutorial',
    description: 'An interactive tutorial for mopm: lessons that build and run Mojo programs in a sandbox.',
    kind: 'tutorial',
    path: TUTORIAL_PATH,
    main: [
      h(doc, 'h1', null, 'Tutorial'),
      h(doc, 'p', { class: 'lede' }, 'Each lesson is a small mopm project you change and run in the page.'),
      h(
        doc,
        'ol',
        { class: 'lesson-list' },
        ...lessons.map((l) => h(doc, 'li', null, h(doc, 'h2', null, h(doc, 'a', { href: internalHref(lessonPath(l)) }, l.title)), h(doc, 'p', null, l.summary))),
      ),
    ],
  };
}

/**
 * The tutorial's pages as [path, page] pairs, the paths of the routes the design names (/tutorial is
 * tutorial/index.html, /tutorial/<lesson> tutorial/<lesson>/index.html); `lessons` in order, as loadLessons gives them.
 */
export function tutorialPages(lessons: readonly Lesson[]): [string, PageSpec][] {
  return [
    ['tutorial/index.html', tutorialIndexPage(lessons)],
    ...lessons.map((l, i): [string, PageSpec] => [`tutorial/${l.id}/index.html`, lessonPage(l, i + 1, lessons.length)]),
  ];
}
