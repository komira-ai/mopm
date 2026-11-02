// docs/configuration.md states more than key names (docs-facts.test.ts holds those): sizes, the registries, the values a
// key allows and defaults, the environment variables, the words of the TOML subset's refusals, the lock versions, the
// platforms. Each of those facts is read here from the source that decides it, so a limit that changes, a registry that
// is renamed, an enum member that is added or a platform that is dropped fails until the page says so. The page's text
// is never copied into an expectation: the expected text is built from the value found in the source.
import { readFileSync } from 'fs';
import { join } from 'path';
import { REPO_ROOT } from './build-fixture';

const read = (p: string) => readFileSync(join(REPO_ROOT, p), 'utf8');
const page = read('docs/configuration.md');

/** The text of the `## ` or `### ` section of the page with this heading, up to the next heading of the same or a higher level. */
function section(heading: string): string {
  const lines = page.split('\n');
  const at = lines.findIndex((l) => /^#{2,3} /.test(l) && l.replace(/^#+ /, '') === heading);
  if (at < 0) throw new Error(`no section ${heading}`);
  const level = /^#+/.exec(lines[at])![0].length;
  let end = lines.length;
  for (let i = at + 1; i < lines.length; i++) {
    const m = /^(#+) /.exec(lines[i]);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }
  return lines.slice(at, end).join('\n');
}

/** The cells of the row of `key` in a section's table of keys (the key cell is a code span). */
function row(sec: string, key: string): string[] {
  const line = sec.split('\n').find((l) => l.startsWith(`| \`${key}\` |`));
  if (!line) throw new Error(`no row for ${key}`);
  return line
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split(/(?<!\\)\|/)
    .map((c) => c.trim());
}

/** The first capture group of `re` in `src`, or a failure that names what was looked for. */
function found(src: string, re: RegExp, what: string): string {
  const m = re.exec(src);
  if (!m) throw new Error(`source: no ${what}`);
  return m[1];
}

const MiB = (n: string) => `${Number(n)} MiB`;

// --------------------------------------------------------------------- sizes

describe('sizes and counts', () => {
  const install = read('src/cli/install_cmd.zig');
  const publish = read('src/cli/publish_cmd.zig');
  const unpack = read('src/core/conda_unpack.zig');

  test('the manifest size limit: every reader of a manifest reads at most what the page says', () => {
    const limits = new Set<string>();
    for (const f of ['src/cli/install_cmd.zig', 'src/cli/main.zig', 'src/cli/publish_cmd.zig']) {
      for (const m of read(f).matchAll(/readFileAlloc\(arena, (?:path|manifest_path|f\.manifest|file), (\d+) << 20\)/g)) limits.add(m[1]);
    }
    expect([...limits]).toEqual(['1']);
    expect(section('mopm.toml')).toContain(`UTF-8 text of at most ${MiB([...limits][0])}`);
  });

  test('the lock size limit', () => {
    const n = found(install, /readFileAlloc\(arena, lock_path, (\d+) << 20\)/, 'lock read');
    expect(section('mopm.lock')).toContain(`reads a lock of at most ${MiB(n)}`);
  });

  test('the readme limit is in bytes and in KiB', () => {
    const bytes = Number(found(publish, /max_readme_bytes: usize = (\d+);/, 'max_readme_bytes'));
    expect(bytes % 1024).toBe(0);
    expect(row(section('`[package]`'), 'readme')[3]).toContain(`${bytes / 1024} KiB (${bytes.toLocaleString('en-US')} bytes)`);
  });

  test('the publish limits: the size of a file and the number of files', () => {
    const file = Number(found(publish, /max_file_bytes: usize = ([\d_]+);/, 'max_file_bytes').replace(/_/g, ''));
    const files = found(publish, /max_files: usize = (\d+);/, 'max_files');
    const refuse = section('What pack and publish refuse');
    expect(file % 1_000_000).toBe(0);
    expect(refuse).toContain(`a package file over ${file / 1_000_000} MB`);
    expect(refuse).toContain(`more than ${files} files for one version`);
    expect(section('A package entry')).toContain(`up to ${file / 1_000_000} MB`);
  });

  test('the unpacked size limits of a package file', () => {
    const member = found(unpack, /member: u64 = (\d+) << 20,/, 'member limit');
    const total = found(unpack, /total: u64 = (\d+) << 20,/, 'total limit');
    expect(section('A package entry')).toContain(`decompress to more than ${MiB(total)} (or one file of more than ${MiB(member)})`);
  });
});

// ------------------------------------------------------------------ registries

describe('registries and the channel', () => {
  const src = read('src/core/registry.zig');
  const named = [...found(src, /const named = \[_\][^{]*\{([\s\S]*?)\n\};/, 'table of named registries').matchAll(/\.\{ "([a-z]+)", "([^"]+)" \}/g)].map((m) => [m[1], m[2]]);

  test('the named registries are the ones the page lists, with their URLs, and the first is the default', () => {
    expect(named.map((n) => n[0])).toEqual(['prod', 'gamma', 'beta']);
    const sec = section('Registries');
    for (const [name, url] of named) expect([name, sec.includes(`\`${name}\``), sec.includes(`\`${url}\``)]).toEqual([name, true, true]);
    expect(sec).toContain(`takes \`${named[0][0]}\` (the default, \`${named[0][1]}\`)`);
  });

  test('the plain-http hosts of a local registry', () => {
    const hosts = [...found(src, /const hosts = \[_\]\[\]const u8\{([^}]*)\}/, 'loopback hosts').matchAll(/"([^"]+):"/g)].map((m) => m[1]);
    expect(hosts).toEqual(['127.0.0.1', '[::1]', 'localhost']);
    expect(section('Registries')).toContain('`127.0.0.1`, `[::1]` or `localhost` with a port');
  });

  test('the channel a lock lists when nothing was fetched', () => {
    const url = found(src, /default_channel_url = "([^"]+)";/, 'default_channel_url');
    expect(section('Registries')).toContain(`the channel its lock lists is \`${url}\``);
    expect(row(section('The top level'), 'channels')[4]).toContain(url);
  });
});

// ------------------------------------------------------------- allowed values

describe('allowed values and defaults', () => {
  const manifest = read('src/core/manifest.zig');
  const metadata = read('src/core/metadata.zig');
  const members = (src: string, name: string) =>
    found(src, new RegExp(`pub const ${name} = enum \\{([^}]*)\\}`), `enum ${name}`)
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
  const quoted = (cell: string) => [...cell.matchAll(/"([a-z]+)"/g)].map((m) => m[1]);

  test('kind of a native dependency allows what the parser enum has, and has no default', () => {
    const kinds = members(manifest, 'NativeDepKind');
    const r = row(section('Native dependencies: `[native-dependencies]`'), 'kind');
    expect(quoted(r[3])).toEqual(kinds);
    expect(r[2]).toBe('none');
    expect(manifest).toMatch(/kind: \?NativeDepKind = null,/);
  });

  test('kind and mode of a native library allow what metadata.zig has, with the defaults of the struct', () => {
    const sec = section('Native libraries: `[native.<id>]`');
    const kind = row(sec, 'kind');
    const mode = row(sec, 'mode');
    expect(quoted(kind[3])).toEqual(members(metadata, 'Kind'));
    expect(quoted(mode[3])).toEqual(members(metadata, 'Mode'));
    const lib = found(manifest, /pub const NativeLib = struct \{([\s\S]*?)\n\};/, 'NativeLib');
    expect(found(lib, /kind: metadata\.Kind = \.(\w+),/, 'default kind')).toBe(quoted(kind[2])[0]);
    expect(found(lib, /mode: metadata\.Mode = \.(\w+),/, 'default mode')).toBe(quoted(mode[2])[0]);
  });

  test('mode of a native dependency allows the same modes, and defaults as the struct does', () => {
    const r = row(section('Native dependencies: `[native-dependencies]`'), 'mode');
    const dep = found(manifest, /pub const NativeDep = struct \{([\s\S]*?)\n\};/, 'NativeDep');
    expect(quoted(r[3])).toEqual(members(metadata, 'Mode'));
    expect(found(dep, /mode: metadata\.Mode = \.(\w+),/, 'default mode')).toBe(quoted(r[2])[0]);
  });

  test('the defaults of the list keys are empty, and of exclusive none, as the struct says', () => {
    const lib = found(manifest, /pub const NativeLib = struct \{([\s\S]*?)\n\};/, 'NativeLib');
    const sec = section('Native libraries: `[native.<id>]`');
    for (const k of ['outputs', 'needs']) {
      expect(lib).toMatch(new RegExp(`${k}: \\[\\]const \\[\\]const u8 = &\\.\\{\\},`));
      expect(row(sec, k)[2]).toBe('empty');
    }
    expect(lib).toContain('exclusive: []const u8 = "",');
    expect(row(sec, 'exclusive')[2]).toBe('none');
    expect(lib).toContain('build: ?[]const u8 = null,');
    expect(row(sec, 'build')[2]).toBe('none');
  });

  test('the targets: lib defaults to src/<name>, and an entry of bins needs name and path', () => {
    expect(read('src/core/unit_graph.zig')).toContain('m.targets.lib orelse try std.fmt.allocPrint(b.arena, "src/{s}", .{m.package.name})');
    expect(row(section('`[targets]`'), 'lib')[2]).toContain('`src/<name>`');
    expect(manifest).toContain('a [targets] bin needs a \'name\'');
    expect(manifest).toContain('a [targets] bin needs a \'path\'');
    expect(manifest).toContain("'lib' in [targets] needs a 'path'");
  });

  test('the reserved package names the page gives as examples are reserved', () => {
    const words = (name: string) => [...found(manifest, new RegExp(`const ${name} = \\[_\\]\\[\\]const u8\\{([\\s\\S]*?)\\};`), name).matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
    const name = row(section('`[package]`'), 'name')[3];
    const fromPage = (kind: string) => found(name, new RegExp(`${kind} \\(([^)]*)\\)`), kind);
    const keywordsOnPage = fromPage('a Mojo keyword');
    const builtinsOnPage = fromPage('a builtin it would shadow');
    for (const w of [...keywordsOnPage.matchAll(/`([a-z_]+)`/g)].map((m) => m[1])) expect([w, words('keywords').includes(w)]).toEqual([w, true]);
    for (const w of [...builtinsOnPage.matchAll(/`([a-z_]+)`/g)].map((m) => m[1])) expect([w, words('builtins').includes(w)]).toEqual([w, true]);
  });

  test('the platform names a lock may hold are the ones closure.zig lists, plus noarch', () => {
    const subdirs = [...found(read('src/core/closure.zig'), /pub const subdirs = \[_\]\[\]const u8\{([^}]*)\}/, 'subdirs').matchAll(/"([^"]+)"/g)].map((m) => m[1]);
    const cell = row(section('A package entry'), 'subdir')[3];
    expect(subdirs).toEqual(['linux-64', 'linux-aarch64', 'osx-arm64']);
    expect([...cell.matchAll(/`([a-z0-9-]+)`/g)].map((m) => m[1])).toEqual(['noarch', ...subdirs]);
  });

  test('the lock versions the page writes are the ones lock.zig writes and reads', () => {
    const lock = read('src/core/lock.zig');
    const v1 = found(lock, /pub const lock_version: i64 = (\d+);/, 'lock_version');
    const v2 = found(lock, /pub const lock_version_2: i64 = (\d+);/, 'lock_version_2');
    expect(row(section('The top level'), 'lock_version')[3]).toBe(`\`${v1}\` or \`${v2}\``);
    expect(lock).toContain('this mopm reads {d}. Update mopm.');
    expect(section('mopm.lock')).toContain(`\`lock_version\` ${v1} is written for a project with \`[toolchain] mojo\`, and ${v2} for \`[package] mojo\``);
  });
});

// ---------------------------------------------------------------- environment

describe('environment variables', () => {
  test('the variables the page lists are the ones the sources read, and no others', () => {
    const reads = new Set<string>();
    for (const f of ['src/cli/main.zig', 'src/cli/test_cmd.zig', 'src/cli/publish_cmd.zig', 'src/core/credentials.zig']) {
      for (const m of read(f).matchAll(/(?:getEnv|getEnvVarOwned)\((?:arena|s\.arena), "([A-Z_]+)"\)/g)) reads.add(m[1]);
    }
    const sec = section('Environment variables');
    const listed = new Set<string>();
    for (const line of sec.split('\n').filter((l) => l.startsWith('| `'))) {
      for (const m of line.split('|')[1].matchAll(/`([A-Z_]+)`/g)) listed.add(m[1]);
    }
    expect([...reads].sort()).toEqual([...listed].sort());
    expect(read('src/core/env.zig')).toContain('/share/max');
    expect(sec).toContain('`MODULAR_HOME` must end in `/share/max`');
  });

  test('a token from the environment wins, and an empty one does not count', () => {
    const publish = read('src/cli/publish_cmd.zig');
    expect(publish).toContain('if (trimmed.len > 0) return trimmed;');
    expect(section('Environment variables')).toContain('when set and not empty; it wins over a stored login');
  });

  test('the config directory order: the flag, then XDG_CONFIG_HOME, then $HOME/.config/mopm', () => {
    const creds = read('src/core/credentials.zig');
    expect(creds).toContain('`$XDG_CONFIG_HOME/mopm`, else `$HOME/.config/mopm`');
    expect(section('credentials.json')).toContain('else `$XDG_CONFIG_HOME/mopm` when `XDG_CONFIG_HOME` is set and not empty, else `$HOME/.config/mopm`');
  });
});

// -------------------------------------------------------------- TOML subset

describe('the TOML subset', () => {
  const toml = read('src/core/toml.zig');
  const sec = section('The TOML subset');

  test('the escapes the page lists are the ones the parser lists', () => {
    // The Zig string literal of the parser's message, then the same escapes as the page writes them.
    expect(toml).toContain('the escapes are \\\\b \\\\t \\\\n \\\\f \\\\r \\\\\\" \\\\\\\\ \\\\uXXXX \\\\UXXXXXXXX"');
    expect(sec).toContain('`\\b \\t \\n \\f \\r \\" \\\\ \\uXXXX \\UXXXXXXXX`');
  });

  test.each([
    ['arrays of tables `[[x]]`', 'arrays of tables ([[...]]) are not supported'],
    ['multi-line strings, `"""` and `\'\'\'`', 'multi-line strings (\\"\\"\\") are not supported'],
    ['floats, dates and times', 'floats are not supported'],
    ['floats, dates and times', 'dates and times are not supported'],
    ['`_` in integers', 'underscores in integers are not supported'],
    ['hexadecimal, octal and binary integers', "only decimal integers are supported ('{s}')"],
    ['without a leading zero', 'an integer may not have a leading zero'],
    ['an inline table extended after it is closed', "is an inline table; it cannot be extended"],
  ])('the page names %s, and the parser refuses it with %s', (pageText, parserText) => {
    expect(sec).toContain(pageText);
    expect(toml).toContain(parserText);
  });

  test('only strings, arrays of strings and tables are values of mopm keys', () => {
    const manifest = read('src/core/manifest.zig');
    expect(manifest).toContain("'{s}' in {s} must be a string, not {s}");
    expect(page).toContain("`'name' in [package] must be a string, not an integer`");
  });
});

// ------------------------------------------------ messages the page quotes

describe('messages the page quotes', () => {
  const manifest = read('src/core/manifest.zig');
  const install = read('src/cli/install_cmd.zig');
  const conda = read('src/core/conda.zig');
  const publish = read('src/cli/publish_cmd.zig');

  test.each([
    ["unknown key 'homepage' in [package]", manifest, "unknown key '{s}' in {s}"],
    ['mopm.toml has no [toolchain] mojo', install, '{s} has no [toolchain] mojo;'],
    ['only mode = "load" is packed', conda, 'only mode = \\"load\\" is packed'],
    ['a pre-release in a requirement has no conda spelling', conda, 'a pre-release in a requirement has no conda spelling'],
    ['digits, no leading zeros, no pre-release or build part', publish, 'digits, no leading zeros, no pre-release or build part'],
    ['Update mopm.', read('src/core/lock.zig'), 'Update mopm.'],
  ])('%s', (onPage, source, inSource) => {
    expect(page).toContain(onPage);
    expect(source).toContain(inSource);
  });

  test('homepage and keywords are in the draft and not in the parser, as the page says', () => {
    expect(manifest).not.toMatch(/"homepage"|"keywords"/);
    expect(read('spec/mopm-toml.md')).toMatch(/^homepage = /m);
    expect(page).toContain('`homepage` and `keywords`, which [the mopm.toml draft](../spec/mopm-toml.md) lists, are not keys of the parser today');
  });
});

// ------------------------------------------------------------------ platforms

describe('platforms', () => {
  const zigTargets = (f: string) => [...found(read(f), /const targets = \[_\]\[\]const u8\{([^}]*)\};/, 'targets').matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  const TARGETS = ['linux-x86_64', 'linux-aarch64', 'macos-arm64'];

  test('the release tools build exactly the targets the home page and the docs list', () => {
    expect(zigTargets('tools/release.zig')).toEqual(TARGETS);
    expect(zigTargets('tools/cut_release.zig')).toEqual(TARGETS);
    const pages = read('site/tools/pages.ts');
    const fromPages = [...found(pages, /export const TARGETS = \[([^\]]*)\]/, 'TARGETS').matchAll(/'([^']+)'/g)].map((m) => m[1]);
    expect(fromPages).toEqual(TARGETS);
  });

  test('the docs that name release files name those three targets and no Intel Mac release', () => {
    for (const f of ['README.md', 'docs/getting-started.md']) {
      const text = read(f).replace(/\s+/g, ' ');
      for (const t of TARGETS) expect([f, t, text.includes(`\`${t}\``)]).toEqual([f, t, true]);
      expect(text).toContain('there is no Intel Mac release');
      expect(text).not.toMatch(/macos-x86_64|macOS \(x86_64|osx-64/);
    }
  });

  test('the install script refuses an Intel Mac, and the page names no Intel Mac platform', () => {
    expect(read('site/static/install.sh')).toContain('Darwin-x86_64) die "no mopm release for Intel Macs');
    expect(page).not.toMatch(/osx-64|macos-x86_64/);
  });
});
