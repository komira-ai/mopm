# Validator corpus

Inputs and recorded verdicts of the registry's package validator. The TypeScript validator
(`service/api/src/validate`) is the first implementation; the Rust port is held to this directory.

| file | what it is |
|---|---|
| `archives/*.conda` | the archives. Not all are valid packages: most are wrong in one way. |
| `cases.json` | every case: the archive, what the publisher declared (`expect`), the limits in force (`limits`, names as in `Limits` of the validator in snake case; a missing key means the default), `allow_native` (the native names the conda-forge name mirror lists for the case: the TypeScript warns about a name it lacks, and the cases are written so that no case warns), `intent` (the rule the case was written to hit, or `ok`) and `what` (the fault, in a line) |
| `verdicts.json` | what the TypeScript validator answered for each case, in order: `{ok: true, facts}` or `{ok: false, rejection_code, rule, message, path?}` |

## Provenance

- **Archives and `cases.json`** are written by `tests/drivers/validator_corpus.zig`, byte by byte (no zip, tar or
  zstd library, and not the TypeScript test builder), with no clock and no random numbers: the zip date is 1980-01-01,
  tar modes and owners are fixed, deflate entries use stored blocks. Regenerate with
  `zig run tests/drivers/validator_corpus.zig -- tests/validator_corpus`. The Buck2 target `//:validator_corpus`
  fails when a committed file is not what the generator makes (and prints the generator's file in base64).
  The files were first made from that output in a CI log, on the date of the pull request that added them.
- **`verdicts.json`** is recorded by `service/api/test/validate/corpus.test.ts` from the TypeScript validator as
  the source tree has it. The test fails when the validator answers otherwise, and when a case's recorded rule is not
  its `intent`: a case that no longer reaches the fault it was written for is reported, not re-recorded.
- When the TypeScript is deleted, the generator and this directory stay (or the generator is deleted and the
  files stay, with this note): the archives and verdicts are the specification the Rust validator is tested against.

## What the cases cover

Names say the layer: `ok_*` valid packages (and the odd encodings the validator accepts); `archive_*` the size, hash and
format checks before any unpacking; `zip_*` and `layout_*` the outer zip and the `.conda` layout; `zstd_*` the
streams, including decompression bombs; `tar_*`, `path_*`, `collision_*` the tars, paths and names that are one file on
another filesystem; `meta_*` the metadata files and their agreement with the request; `order_*` inputs that are wrong in
two ways, which fix the order the rules are applied in; `limit_*` every size limit one below, at and one above its
value (the same archive with three limits).

## What it does not do

The verdict of a case is the TypeScript behaviour, right or not. A decompression bomb is judged by the collector
counters of the TypeScript, which a streaming implementation reproduces by the same counters, not by memory use.
bzip2 (`.tar.bz2`) archives are refused by the format rule and not unpacked, so there is no bzip2 corpus.
There is no fuzzer here: a seeded fuzzer that feeds one input to both implementations belongs with the Rust validator.
