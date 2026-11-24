# The interactive tutorial's lessons

Each lesson of the tutorial at `/tutorial/<id>` is one directory here. The site build renders its text and its
editor from `lesson.md` and `lesson.json`; the sandbox template build (`tutorial/template`, README.md there) copies
its `project/` to `/home/user/lessons/<id>/` in the sandbox and runs `mopm sync --locked` there, and the page writes the
editable files there and runs the lesson's actions.

```text
tutorial/lessons/<id>/
  lesson.md      the lesson's text (Markdown, rendered by the site's restricted renderer under the title)
  lesson.json    title, summary, order, editable files and actions (spec/tutorial-lesson.schema.json)
  project/       a mopm project: mopm.toml, mopm.lock (written by `mopm lock`), its sources
```

- `<id>` is lower-case letters and digits in words joined by single hyphens (`hello`, `structs-2`): it is the
  route of the page.
- `lesson.md` is the text below the page's heading, which is `lesson.json`'s `title`: it starts with the text, not
  with a `#` title, and its own headings sit one level below the page's (`#` is shown as a second-level heading).
- `lesson.json` follows `spec/tutorial-lesson.schema.json`, which is the contract between the two builds:
  - `title` and `summary`, for the index and the page;
  - `order`, the lesson's place from 1, one lesson per number;
  - `editable`, the files the page shows in an editor, as paths relative to `project/` (no `..`, no absolute path,
    no backslash); each must be a file under `project/`;
  - `actions`: `run` always, and `test` when the lesson has tests: the command each button runs in the lesson's
    directory. `run` names the program, as `mopm run` requires (`mopm run src/main.mojo`); `test` is `mopm test ...`.
- `project/mopm.lock` is what `mopm lock` writes for `project/mopm.toml`: after changing the manifest, run
  `mopm lock` in `project/` and commit both.

`//:tutorial_lessons` (`tests/drivers/tutorial_lessons.zig`) checks every lesson here against all of this on each
pull request. `//:autolink` (after the merge, with the real Mojo) runs `hello`'s `run` action in a copy of its project
and checks that it prints `Hello, world!`. `hello` is the first lesson; the tutorial's pages add further lessons under the same schema and may
change `hello`.
