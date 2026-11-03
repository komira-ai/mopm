# The previous release's request parsers (v0.0.104), pinned

`group-request.ts` and `group-commit.ts` are the code the registry of the release tagged `v0.0.104` (komira-ai/mopm d0b9020) used to
read a create request (`parseGroupRequest`, `groupIdFor`: `service/api/src/publish/group-service.ts` lines 63-131) and a commit request
(`parseGroupCommit`: `service/api/src/publish/group-commit.ts` lines 29, 31 and 40-67). After the import lines at the top of each file (the
only lines written here) the text is the release's, byte for byte. `test/compat/group-requests-v0.0.104.test.ts` runs the current
command line's request bodies through them.

Whole files are not vendored: the two files import most of the registry (the group store, the lifecycle, the ports), several thousand
lines, none of it needed to parse a request. The imports name the same modules of the current tree; `git diff v0.0.104 --stat --
service/api/src` shows that only the group service, the commit, the keys, the router and a new readme module changed since the tag, and
none of the modules these two files import is among them.

`SHA256SUMS` holds the sha256 of each file; the test checks both before it runs them (`sha256sum -c SHA256SUMS` does it by hand). Do not
edit these files. To regenerate: write the import lines, then append `git show v0.0.104:<path> | sed -n <lines>p` for the ranges above.
