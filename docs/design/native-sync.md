# `mopm sync` installs the environment itself

## The problem

`mopm sync` used to write a pixi project under `.mopm` and run pixi, so a user needed pixi, and the install was
whatever pixi's solver and cache made of it. Now mopm installs the environment from files it already pins: the
lock's packages and system libraries, and the Mojo toolchain's closure built into mopm (or a file named by
`--toolchain`). Every file has a sha256 and a size. There is no solver.

## Layout

- `.mopm/env`: the environment. `.mopm/env/conda-meta/mopm-stamp` records what it holds.
- `.mopm/pkgs/<file>`: locked registry files.
- `.mopm/sync.lock`: the project lock (below).
- `.mopm/.env.tmp-*`, `.mopm/.env.old-*`: a candidate and a backup, present only while a sync runs or after one was
  interrupted.
- `<cache>/<sha256>/<file>`: the toolchain's and the system libraries' files, shared by every project. The cache
  is `--cache <dir>`, else `$XDG_CACHE_HOME/mopm/pkgs`, else `~/.cache/mopm/pkgs`; with none of the three
  usable, sync says to pass `--cache`.

## The transaction

A sync takes the project lock, then:

1. Recover. If `.mopm/env` is missing and backups `.env.old-<n>` exist, the one with the highest `n` is renamed back
   (commit numbers each backup one past the highest it finds, so a backup a failed delete left behind is always
   older than the one a later cut sync left). With two or more backups of which one is not numbered, none is
   touched and a warning asks the user to rename the right one. Candidates `.env.tmp-*` are deleted; backups are
   deleted only when `.mopm/env` exists. A failed delete is a warning.
2. Plan and decide. The install list is the toolchain, then the system libraries, then the locked packages. Sync
   compares the stamp with the list. If it matches and the environment verifies (below), nothing is downloaded.
3. Fetch every file, checking size and sha256.
4. Stage a candidate beside `.mopm/env`: unpack every archive, rewrite the prefix placeholders, write the conda
   metadata and the stamp. A path installed by two packages is allowed only when both are regular files with the
   same sha256 and the same execute bit; any other overlap is refused, naming the path and both packages. An
   archive path with a `.` or empty component is refused, so every installed file has one spelling and the overlap
   check compares like with like. An archive whose name, version
   or build is not a single safe path component (no separator, no NUL or control byte, not `.` or `..`) is
   refused before anything named after it is written; a lock or closure naming such a package is refused too.
5. Verify the candidate: each package's metadata and sha256, each native library's hash, each system library's
   record, and that no `lib/mojo/*.mopm.json` is installed that the lock does not name.
6. Commit: rename `.mopm/env` to a backup `.env.old-<n>`, rename the candidate to `.mopm/env`, delete the backup. If the second
   rename fails, the backup is renamed back; if that fails too, the backup stays and the error names it, and the
   next sync puts it back (step 1). A failed delete of the backup is a warning.

What each failure leaves: before step 6 the old environment is untouched (the candidate is deleted); in step 6
it is the old environment or the whole new one, or, after a double failure, a backup that the next sync restores.

## The project lock

`.mopm/sync.lock` is locked exclusively for the whole sync. A second sync prints
`mopm sync: waiting for another mopm sync of this project to finish (.mopm/sync.lock)` and waits, so one sync
never deletes another's candidate or backup.

## Cache ownership and placement

Cache files are named by their sha256, so two projects pinning different bytes under one file name never share an
entry. Before anything is created, the cache path is resolved component by component, every existing component through
its symlinks (also one reached again by `..` after a component that does not exist yet), and refused when it is
`.mopm/env`, inside it, or inside a candidate or backup directory: those are replaced by the sync. A path through a
symlink whose target does not exist is refused. The sync then creates and uses the resolved path, not the one given,
so what was checked is what is written. A cache path
that cannot be made is an error and the environment is unchanged. Locked registry files stay in `.mopm/pkgs`.

## The stamp and repair

The stamp is `mopm-env 2`, the absolute prefix, and one line per file (name, version, file name, sha256, size).
Moving the project changes the prefix, so the environment is installed again and its placeholders point at the new
path. The stamp alone is not trusted: the shortcut is taken only when the locked packages, their natives and the
libraries verify and, for every file, its conda metadata record exists with the file's sha256 and every path that
record lists exists. If the stamp matches but this fails, sync says why on standard error and installs again. A
missing or malformed stamp means a full install.

## System libraries

The lock's `system_libs` for the host's subdir are installed after the toolchain. A library the toolchain also
holds with the same sha256 is installed once; with a different sha256 it replaces the toolchain's file and sync
warns, naming both. A locked package whose conda name is a toolchain or library name is refused.

## The version 2 closure check

A version 2 lock records the sha256 of the toolchain closure for each Mojo version and platform. Sync computes the
same hash for the closure it is about to install (built in, or from `--toolchain`) and refuses a difference before
any download. A mirror, with the same pins at other URLs, has the same hash. A version 1 lock records none and is
not checked.

## Compatibility

The lock format is unchanged and version 1 and version 2 locks both install. `--pixi` is removed. Sync never reads,
moves or deletes `.mopm/.pixi`, `.mopm/channel` or `.mopm/pixi.toml` from an earlier mopm; they can be deleted by
hand. An environment made by an earlier mopm has an older stamp, so it is installed again once.

## What is not done

There is no solver. On the current path the toolchain's files are checked for presence, not hashed again; the
bytes were checked when they were downloaded.
