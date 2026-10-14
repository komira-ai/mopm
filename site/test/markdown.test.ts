// The Markdown subset renders as CommonMark/GFM would, and what is not supported stays literal text.
import { MAX_DEPTH, parse } from '../src/markdown/parse';
import { Slugger, slugify } from '../src/markdown/render';
import { md, mdFull } from './md';

describe('blocks', () => {
  test('ATX headings, with closing hashes and a shift', () => {
    expect(md('# Title\n## Sub ##\n###### six')).toBe(
      '<h1 id="readme-title">Title</h1><h2 id="readme-sub">Sub</h2><h6 id="readme-six">six</h6>',
    );
    expect(md('# a\n###### b', { idPrefix: '', headingShift: 1, links: { mode: 'readme' } })).toBe(
      '<h2 id="a">a</h2><h6 id="b">b</h6>',
    );
    expect(md('#nospace')).toBe('<p>#nospace</p>');
  });

  test('paragraphs join lines; two trailing spaces or a backslash make a hard break', () => {
    expect(md('a\nb\n\nc')).toBe('<p>a\nb</p><p>c</p>');
    expect(md('a  \nb\\\nc')).toBe('<p>a<br>b<br>c</p>');
  });

  test('fenced code keeps its text verbatim and escapes it', () => {
    expect(md('```mojo\nfn f() -> Int:\n    return 1 < 2\n```')).toBe(
      '<pre><code class="language-mojo">fn f() -&gt; Int:\n    return 1 &lt; 2</code></pre>',
    );
    expect(md('~~~\n```\n~~~')).toBe('<pre><code>```</code></pre>');
    expect(md('```bad"lang\nx\n```')).toBe('<pre><code>x</code></pre>');
    expect(md('```\nunclosed')).toBe('<pre><code>unclosed</code></pre>');
  });

  test('indented code', () => {
    expect(md('    a\n\n    b\n')).toBe('<pre><code>a\n\nb</code></pre>');
    expect(md('para\n    not code')).toBe('<p>para\nnot code</p>');
  });

  test('thematic breaks', () => {
    expect(md('***\n- - -\n___')).toBe('<hr><hr><hr>');
  });

  test('block quotes, with lazy continuation', () => {
    expect(md('> a\nb\n> # h')).toBe('<blockquote><p>a\nb</p><h1 id="readme-h">h</h1></blockquote>');
  });

  test('tight and loose lists, nested lists, ordered start', () => {
    expect(md('- a\n- b')).toBe('<ul><li>a</li><li>b</li></ul>');
    expect(md('- a\n\n- b')).toBe('<ul><li><p>a</p></li><li><p>b</p></li></ul>');
    expect(md('1. one\n   more\n2. two\n   - x\n   - y')).toBe(
      '<ol><li>one\nmore</li><li>two<ul><li>x</li><li>y</li></ul></li></ol>',
    );
    expect(md('3) c\n4) d')).toBe('<ol start="3"><li>c</li><li>d</li></ol>');
    expect(md('- a\n+ b')).toBe('<ul><li>a</li></ul><ul><li>b</li></ul>');
    expect(md('* lazy\ncontinued')).toBe('<ul><li>lazy\ncontinued</li></ul>');
    expect(md('- a\n\n  second para')).toBe('<ul><li><p>a</p><p>second para</p></li></ul>');
  });

  test('an ordered list interrupts a paragraph only when it starts at 1', () => {
    expect(md('text\n2. no')).toBe('<p>text\n2. no</p>');
    expect(md('text\n1. yes')).toBe('<p>text</p><ol><li>yes</li></ol>');
  });

  test('GFM tables with alignment, escaped pipes and ragged rows', () => {
    expect(md('| a | b | c |\n|:--|--:|:-:|\n| 1 | `x\\|y` |\n| 4 | 5 | 6 | 7 |')).toBe(
      '<table><thead><tr><th scope="col" class="align-left">a</th><th scope="col" class="align-right">b</th>' +
        '<th scope="col" class="align-center">c</th></tr></thead><tbody>' +
        '<tr><td class="align-left">1</td><td class="align-right"><code>x|y</code></td></tr>' +
        '<tr><td class="align-left">4</td><td class="align-right">5</td><td class="align-center">6</td></tr></tbody></table>',
    );
    expect(md('a | b\n--- | ---')).toBe('<table><thead><tr><th scope="col">a</th><th scope="col">b</th></tr></thead></table>');
    expect(md('a | b\n--- | --- | ---')).toBe('<p>a | b\n--- | --- | ---</p>');
  });
});

describe('inlines', () => {
  test('emphasis and strong emphasis follow the flanking rules', () => {
    expect(md('*a* **b** _c_ __d__ ***e***')).toBe(
      '<p><em>a</em> <strong>b</strong> <em>c</em> <strong>d</strong> <em><strong>e</strong></em></p>',
    );
    expect(md('snake_case_name and 2*3*4')).toBe('<p>snake_case_name and 2<em>3</em>4</p>');
    expect(md('* not emphasis *')).toBe('<ul><li>not emphasis *</li></ul>');
    expect(md('a * b * c')).toBe('<p>a * b * c</p>');
    expect(md('**unclosed')).toBe('<p>**unclosed</p>');
    expect(md('*a **b** c*')).toBe('<p><em>a <strong>b</strong> c</em></p>');
  });

  test('code spans take precedence and keep their text', () => {
    expect(md('`a*b*c` and ``x ` y``')).toBe('<p><code>a*b*c</code> and <code>x ` y</code></p>');
    expect(md('`unclosed *em*')).toBe('<p>`unclosed <em>em</em></p>');
    expect(md('` <b> `')).toBe('<p><code>&lt;b&gt;</code></p>');
  });

  test('backslash escapes', () => {
    expect(md('\\*not\\* \\[x\\](y)')).toBe('<p>*not* [x](y)</p>');
  });

  test('inline links, titles, angle destinations and balanced parentheses', () => {
    const rel = 'rel="nofollow noopener noreferrer ugc"';
    expect(md('[a](https://mopm.dev/p "t")')).toBe(`<p><a href="https://mopm.dev/p" ${rel}>a</a></p>`);
    expect(md('[a](<https://mopm.dev/a b>)')).toBe(`<p><a href="https://mopm.dev/ab" ${rel}>a</a></p>`);
    expect(md('[w](https://mopm.dev/wiki/A_(b))')).toBe(
      `<p><a href="https://mopm.dev/wiki/A_(b)" ${rel}>w</a></p>`,
    );
    expect(md('[*em* `c`](https://mopm.dev)')).toBe(`<p><a href="https://mopm.dev/" ${rel}><em>em</em> <code>c</code></a></p>`);
    expect(md('[no](https://mopm.dev')).toBe('<p>[no](https://mopm.dev</p>');
    expect(md('[a] [b][c]')).toBe('<p>[a] [b][c]</p>');
  });

  test('no links inside links', () => {
    expect(md('[a [b](https://mopm.dev/b) c](https://mopm.dev/a)')).toBe(
      '<p>[a <a href="https://mopm.dev/b" rel="nofollow noopener noreferrer ugc">b</a> c](https://mopm.dev/a)</p>',
    );
  });

  test('autolinks', () => {
    expect(md('<https://mopm.dev> <me@mopm.dev>')).toBe(
      '<p><a href="https://mopm.dev/" rel="nofollow noopener noreferrer ugc">https://mopm.dev</a> ' +
        '<a href="mailto:me@mopm.dev" rel="nofollow noopener noreferrer ugc">me@mopm.dev</a></p>',
    );
  });

  test('images are never loaded: they become a link reading "image: alt"', () => {
    expect(md('![logo *x*](https://mopm.dev/a.png)')).toBe(
      '<p><a href="https://mopm.dev/a.png" rel="nofollow noopener noreferrer ugc">image: logo x</a></p>',
    );
    expect(md('![](https://mopm.dev/a.png)')).toContain('>image</a>');
    expect(md('![alt](rel.png)')).toBe('<p>image: alt</p>');
  });

  test('in-page fragments get the id prefix', () => {
    expect(md('# Install\n[see](#install)')).toBe('<h1 id="readme-install">Install</h1><p><a href="#readme-install">see</a></p>');
  });
});

describe('literal fallbacks', () => {
  test('raw HTML is text, counted once per tag', () => {
    const r = mdFull('<div onclick="x()">hi</div>\n\n<!-- c -->');
    expect(r.html).toBe('<p>&lt;div onclick="x()"&gt;hi&lt;/div&gt;</p><p>&lt;!-- c --&gt;</p>');
    expect(r.fallbacks).toBe(3);
  });

  test('setext underlines and reference definitions stay text, counted', () => {
    const r = mdFull('Title\n=====\n\n[x]: https://mopm.dev');
    expect(r.html).toBe('<p>Title</p><p>=====</p><p>[x]: https://mopm.dev</p>');
    expect(r.fallbacks).toBe(2);
  });

  test('entities are not decoded', () => {
    expect(md('&amp; &#60;')).toBe('<p>&amp;amp; &amp;#60;</p>');
  });

  test(`containers nest at most ${MAX_DEPTH} deep; deeper content is literal`, () => {
    const r = mdFull('>'.repeat(40) + ' deep');
    expect(r.html.split('<blockquote>').length - 1).toBe(MAX_DEPTH);
    expect(r.html).toContain('<p>' + '&gt;'.repeat(40 - MAX_DEPTH) + ' deep</p>');
    expect(r.fallbacks).toBe(1);
  });

  test('deeply nested emphasis keeps its text past the inline depth cap', () => {
    const n = 5000;
    const src = '*a '.repeat(n) + 'x' + ' a*'.repeat(n);
    const { blocks } = parse(src);
    expect(blocks).toHaveLength(1);
    const html = md(src);
    expect(html.split('<em>').length - 1).toBeLessThanOrEqual(40);
    expect(html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ')).toBe(`${'a '.repeat(n)}x${' a'.repeat(n)}`);
  });
});

describe('slugs', () => {
  test('GitHub-style slugs', () => {
    expect(slugify('`[package]` display fields')).toBe('package-display-fields');
    expect(slugify('Retries and FLAKY')).toBe('retries-and-flaky');
    expect(slugify('Ünïcode & co_de')).toBe('ünïcode--co_de');
  });

  test('repeats are numbered and never collide', () => {
    const s = new Slugger();
    expect(['A', 'A', 'A-1', 'A', '!!!'].map((t) => s.slug(t))).toEqual(['a', 'a-1', 'a-1-1', 'a-2', 'section']);
  });

  test('rendered headings get unique ids', () => {
    expect(md('# A\n# A\n# A-1')).toBe('<h1 id="readme-a">A</h1><h1 id="readme-a-1">A</h1><h1 id="readme-a-1-1">A-1</h1>');
  });
});
