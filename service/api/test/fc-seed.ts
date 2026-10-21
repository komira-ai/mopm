// jest `setupFiles`: one fixed seed for every fast-check property in this package, so a run measures the same
// inputs every time. Unseeded, the generated inputs differ per run and so does the branch coverage of
// src/validate/zip.ts (a branch is reached on some runs and not on others), which an exact floor
// (coverage_floor.txt) cannot hold. The site's markdown-fuzz test seeds its own property the same way.
import * as fc from 'fast-check';

fc.configureGlobal({ seed: 20261014 });
