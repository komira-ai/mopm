# Contributing

- Tooling is written in Zig 0.12.0. Run `zig build test` from the repository
  root before opening a pull request; CI runs it on Linux (x86_64, aarch64) and
  macOS (arm64).
- A bug fix comes with a test that failed before the fix.
- A behaviour change updates the golden files in `tests/golden` in the same
  pull request, and says why.
- Keep files small and the public surface smaller. Document only what the code
  does.
- Open an issue before a large change.
- By contributing you agree your work is licensed under Apache-2.0.
