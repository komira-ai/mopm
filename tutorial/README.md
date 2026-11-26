# The interactive tutorial's lessons

Each lesson of the tutorial at `/tutorial/<id>` is one directory here. The site build renders its text and its
editor from `lesson.md` and `lesson.json`; the sandbox template build (`tutorial/template`, README.md there) copies
its `project/` to `/home/user/lessons/<id>/` in the sandbox and runs `mopm sync --locked` there, and the page writes the
editable files there and runs the lesson's actions.

```text
tutorial/lessons/<id>/
  lesson.md      the lesson's text (Markdown, rendered by the site's restricted renderer under the title), with
                 what each action prints
  lesson.json    title, summary, order, editable files and actions (spec/tutorial-lesson.schema.json)
  project/       a mopm project: mopm.toml, mopm.lock (written by `mopm lock`), its sources
```

- `<id>` is lower-case letters and digits in words joined by single hyphens (`hello`, `structs-2`): it is the
  route of the page.
- `lesson.md` is the text below the page's heading, which is `lesson.json`'s `title`: it starts with the text, not
  with a `#` title, and its own headings sit one level below the page's (`#` is shown as a second-level heading).
- `lesson.md` shows what each action of `lesson.json` prints, in a fenced block whose info string is `output` and
  the action's name, one block per action and none for an action the lesson does not have:

  ````text
  ```output run
  Hello, world!
  ```
  ````

  The page shows it as code labelled `output`. Blank lines at the start and white space at the end do not count, and
  nor do the digits of a test's time, `(81 ms)` in `mopm test`'s line for each test, which change from run to run.
- `lesson.json` follows `spec/tutorial-lesson.schema.json`, which is the contract between the two builds:
  - `title` and `summary`, for the index and the page;
  - `order`, the lesson's place from 1, one lesson per number;
  - `editable`, the files the page shows in an editor, as paths relative to `project/` (no `..`, no absolute path,
    no backslash); each must be a file under `project/`, UTF-8 text with LF line ends and no NUL (the lesson's page
    carries its text as HTML, which would read a CR as a newline; the site build refuses one, `site/tools/lessons.ts`);
  - `actions`: `run` always, and `test` when the lesson has tests: the command each button runs in the lesson's
    directory. `run` names the program, as `mopm run` requires (`mopm run src/main.mojo`); `test` is `mopm test ...`.
- `project/mopm.lock` is what `mopm lock` writes for `project/mopm.toml`: after changing the manifest, run
  `mopm lock` in `project/` and commit both.

`//:tutorial_lessons` (`tests/drivers/tutorial_lessons.zig`) checks every lesson here against all of this on each
pull request. `//:autolink` (`tests/drivers/test_autolink_test.zig`, with the real Mojo: on the farm after the merge,
and in `ci.yml`'s `mojo-e2e` on Linux x86_64, Linux arm64 and macOS arm64) runs every action of every lesson in a copy
of its project and checks that it exits 0 and prints its output block (`tests/drivers/lesson_output.zig`). So a
lesson whose code does not build, or whose program prints something else, fails there.
