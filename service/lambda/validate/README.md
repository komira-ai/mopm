# mopm_validate

The package validator of the registry, ported from `service/api/src/validate`. Pure: bytes in, verdict out, no I/O;
a hostile or malformed archive yields a rejected verdict with a stable rule and rejection code and never panics.

| module | ports | notes |
|---|---|---|
| `zip` | `zip.ts` | the outer zip of a `.conda`: central directory cross-checked against every local header, overlapping entries (the zip quine), encryption, zip64, multi-disk, methods other than stored and deflate refused; CRC-32 checked. Hand-written: the `zip` crate normalises what this must refuse |
| `tar` | `tar.ts` | entry types, paths, pax and GNU long names, the shared file and byte budget. Hand-written for the same reason |
| `zstd` | `zstd-read.ts` | frame walking with fzstd's policy on top of `ruzstd` (see the module header); every decoder error is "is not valid zstd" |
| `collector` | `collector.ts` | receives decompressed output and stops it past the byte cap or the ratio guard |
| `layout` | `layout.ts` | name collisions after NFKC and case folding; the layout allow-list |
| `metadata` | `metadata.ts` | `<name>.mopm.json` and `info/index.json`, and how `depends` must agree with them |
| `codes` | `codes.ts` | the rule codes and their mapping to the contract's rejection codes |
| `js` | | the JavaScript behaviours verdicts depend on: lenient `parseInt`, `\s`, `TextDecoder`'s byte order mark, `path.posix` |

bzip2 (`.tar.bz2`) is detected and refused as `format_not_allowed`; nothing here reads it (the TypeScript never does with
its default options either).

## What holds it

`corpus_replay` replays `tests/validator_corpus` (komira-ai/mopm#88): 217 inputs, each with the verdict the TypeScript
validator gave (acceptance, rule, rejection code, message, path, and for an accepted package the facts). Every Rust
verdict must equal it as JSON, and each case must still reach the rule it was written for. The archives reach the test
through `src/corpus_table.rs` (a test run reads only what it compiles in); the test fails, naming the line, when the
table does not list exactly the archives `cases.json` names. Unit tests per module hold the rules the corpus does not
(a zip written by hand with one fault at a time, tar headers, the pax and long-name paths, the JavaScript helpers).

## Differences that are not in the corpus

* A zstd frame's content checksum is not verified (fzstd does not either); `ruzstd` itself verifies it when the frame
  is read to its end only if asked, and this reader does not ask.
* JSON is parsed by `serde_json`, JavaScript's `JSON.parse` differs on lone surrogate escapes (`"\ud800"` is valid there,
  an error here) and on nesting deeper than 128 levels. The corpus has neither.
* A seeded fuzzer that feeds the same bytes to both implementations needs Node; it is not here.
