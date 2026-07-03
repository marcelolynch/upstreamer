# upstreamer

A prototype tool that automates the "is this file ready to upstream?"
loop for downstream projects (like
[toric](https://github.com/YaelDillies/toric) or
[Carleson](https://github.com/leanprover-community/carleson)) that stage
upstreaming candidates under a `Mathlib/` or `ToMathlib/` subdirectory.

The tool itself is upstream-agnostic — every "well-known" piece of
Mathlib-specific knowledge lives in the **`mathlib` preset** rather than
in the workflow. For projects that upstream somewhere else, just don't
use the preset and supply the equivalent values explicitly.

Given a candidate `.lean` file in the downstream and a local upstream
clone, the tool:

1. Refuses to run if either working tree is dirty.
2. Audits the candidate's imports — refuses to proceed if it depends on
   sibling staging files or other downstream code.
3. Copies the candidate to its target path inside the local upstream
   (path-mirror convention; override with `--target`). If the target
   already exists, copies as `…_Upstreamed.lean` instead.
4. Runs `lake exe cache get` then `lake build <target-module>` in the
   upstream. On failure, removes the copy and stops.
5. Rewrites the downstream's `[[require]] name = <upstream-name>` to
   point at the local clone (via Hopscotch's
   `LakefileProcessor.setPathAny`) and runs `lake update <upstream-name>`.
6. Replaces the original candidate file with a `module / public import …`
   re-export stub pointing at the upstreamed module — so the rest of the
   downstream's source keeps building unchanged.
7. Runs `lake build` in the downstream. If it succeeds, the file is
   upstream-ready (modulo merging the `_Upstreamed` variant, if any).

## Usage

```
lake exe upstreamer <candidate.lean> \
  --upstream-path /path/to/local/upstream \
  --preset mathlib \
  [--downstream /path/to/downstream] \
  [--target Mathlib/LinearAlgebra/Finsupp/LinearCombination.lean] \
  [--search-root Toric.Mathlib] \
  [--no-verify-clean]
```

`--preset mathlib` fills in:

- `--upstream-name = mathlib` (the lakefile dep name in
  `[[require]] name = "mathlib"`)
- `--upstream-namespace = Mathlib` (target-path prefix and post-validate
  state filter)
- search-root auto-detection via `Mathlib` / `ToMathlib` path components

Without a preset, you must supply `--upstream-name` and
`--upstream-namespace` yourself, and `--search-root` (since auto-detection
is preset-driven).

The candidate argument can be a file path (absolute or relative to CWD)
or a dotted Lean module name resolved against `--downstream`.

After validate succeeds the workspace is dirty by design. Subcommands:

| Subcommand | What |
|---|---|
| (default) | The full validate workflow (audit + copy + mathlib build + redirect + stub + downstream build). |
| `stage` | Everything `validate` does except the two builds. Use to iterate before paying for a full build. |
| `stage --dry-run` | Sanity check + import audit only. Triages a candidate without touching anything. |
| `build` | Re-run upstream + downstream builds without re-copying anything. |
| `commit` | Stage two PR-ready branches in both repos. |
| `revert` | Undo a stage/validate. |
| `baseline` | Pre-flight: does the downstream build against the local upstream AS-IS? |

Pass `--verbose` (or `-v`) to any of the build-running subcommands
(`baseline`, `stage`, `build`, the default validate) to stream
`lake`'s output live; otherwise it's captured and only surfaced if a
build fails.

Pass `--replace-imports` to `validate` (or `stage`) to skip the
re-export stub: instead, the candidate is deleted and every
`import <source-module>` line in the downstream is rewritten to the
upstreamed module. `commit` then commits whatever shape the workspace
is in — the flag belongs to whatever set the workspace up.

See [SCENARIOS.md](SCENARIOS.md) for the full lifecycle with concrete
chains and [DEMO.md](DEMO.md) for a worked example.

## Config: `.upstreamer`

Drop a `.upstreamer` file at the downstream's root to supply defaults.
The tool walks upward from CWD to find it.

For a Mathlib downstream:

```
preset        = mathlib
upstream-path = ../mathlib
```

That's all you need. With this in place, every command shortens to
`upstreamer <subcommand> <candidate>` from anywhere inside the
downstream repo.

If the downstream isn't your repo, don't commit `.upstreamer` — it would
dirty the tree and the tool refuses to run dirty. Exclude it locally with
`echo .upstreamer >> .git/info/exclude` instead.

For a non-Mathlib upstream:

```
upstream-path      = ../my-upstream
upstream-name      = my-upstream         # the [[require]] dep name
upstream-namespace = MyUpstream          # the namespace prefix
search-root        = MyProject.Staging   # the staging-area namespace
```

(Or use a preset and override individual fields — CLI > config > preset.)

Format is `key = value` per line; `#` and `;` start comments; blank
lines OK; unknown keys are silently ignored. Relative paths are resolved
against the file's directory.

Recognized keys (all match a CLI flag of the same name):

| Key | Meaning |
|---|---|
| `preset` | Preset name (currently only `mathlib`) |
| `upstream-path` | Path to the local upstream clone |
| `upstream-name` | Lakefile dep name |
| `upstream-namespace` | Namespace prefix in the upstream |
| `search-root` | Staging-area namespace in the downstream |

## Caveats

- The upstream commit pinned in the downstream's `lake-manifest.json` may
  differ from your local clone's HEAD; build failures may then reflect
  API drift rather than upstreaming readiness. Run `upstreamer baseline`
  first to confirm the downstream still builds against your local
  upstream AS-IS.
- Single-file scope only. If the candidate transitively depends on other
  staging files, the tool refuses up front; you must upstream those first.
- No automated post-commit revert: `commit` prints the exact commands
  for abandoning the staged branches; the in-tree `revert` subcommand
  only handles the pre-commit dirty state.
