# upstreamer

A prototype tool that automates the "is this file ready to upstream to Mathlib?"
loop for projects (like [Carleson](https://github.com/leanprover-community/carleson))
that stage upstreaming candidates under a `Mathlib/` or `ToMathlib/` subdirectory.

Given a candidate `.lean` file in the downstream project and a local Mathlib
checkout, the tool:

1. Refuses to run if either working tree is dirty.
2. Audits the candidate's imports — refuses to proceed if it depends on
   sibling staging files or other downstream code.
3. Copies the candidate to its target path inside the local Mathlib (using
   the path-mirror convention; override with `--target`). If the target
   already exists, copies as `…_Upstreamed.lean` instead.
4. Runs `lake exe cache get` then `lake build <target-module>` in Mathlib.
   On failure, removes the copy and stops.
5. Rewrites the downstream's `mathlib` `[[require]]` to point at the local
   Mathlib (via Hopscotch's `LakefileProcessor.setPathAny`) and runs
   `lake update mathlib`.
6. Replaces the original candidate file with a `module / public import …`
   re-export stub pointing at the upstreamed module — so the rest of the
   downstream's source keeps building unchanged.
7. Runs `lake build` in the downstream. If it succeeds, the file is
   upstream-ready (modulo merging the `_Upstreamed` variant, if any).

## Usage

```
lake exe upstreamer <candidate.lean> \
  --downstream /path/to/downstream \
  --mathlib    /path/to/local/mathlib \
  [--target Mathlib/Order/MinLayer.lean] \
  [--search-root Carleson.ToMathlib] \
  [--no-verify-clean] \
  [--dry-run]
```

The candidate path may be absolute or relative to the current directory. By
default `--downstream` is `.` and the search root is auto-detected from the
candidate's path components (looks for a `Mathlib` or `ToMathlib` segment).

`--dry-run` runs only the cheap checks (Phases 0–2: working-tree status,
import audit, target-path computation, collision detection) and exits without
touching any files. Each invocation finishes in tens of milliseconds, so
sweeping the dashboard's whole `ready_to_upstream` list is a sub-second
operation. Every run — dry or full — ends with a tab-separated `RESULT  …`
line for batch consumers to grep.

## Caveats

- The mathlib commit in the downstream's `lake-manifest.json` may differ from
  `mathlib-local`'s HEAD. The tool prints a warning and continues; build
  failures may reflect API drift rather than upstreaming readiness.
- Single-file scope only. If the candidate transitively depends on other
  staging files, the tool refuses up front; you must upstream those first.
- No automated revert. To undo a run: `git checkout . && git clean -fd` in
  both repos, then `lake update mathlib` in the downstream.
