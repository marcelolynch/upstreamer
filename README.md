# upstreamer

A tool that automates the "is this file ready to upstream?" loop for downstream
projects (like [toric](https://github.com/YaelDillies/toric) or
[Carleson](https://github.com/leanprover-community/carleson)) that stage
upstreaming candidates under a `Mathlib/` or `ToMathlib/` subdirectory.

The tool is upstream-agnostic — Mathlib-specific knowledge lives in the
`mathlib` preset rather than in the core workflow. For projects upstreaming
elsewhere, supply equivalent values explicitly instead of using the preset.

Given a candidate `.lean` file in the downstream and a local upstream
clone, the tool:

1. Refuses to run if either working tree is dirty.
2. Audits the candidate's imports — refuses to proceed if it depends on
   sibling staging files or other downstream code.
3. Copies the candidate to its target path in the upstream (path-mirror
   convention; override with `--target`). If the target already exists,
   copies as `…_Upstreamed.lean` instead.
4. Runs `lake exe cache get` then `lake build <target-module>` in the
   upstream. On failure, removes the copy and stops.
5. Rewrites the downstream's `[[require]] name = <upstream-name>` to
   point at the local clone (via Hopscotch's
   `LakefileProcessor.setPathAny`) and runs `lake update <upstream-name>`.
6. Replaces the candidate file with a `module / public import …` re-export
   stub pointing at the upstreamed module, so the downstream's source keeps
   building unchanged.
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

- `--upstream-name = mathlib` (the lakefile dep name in `[[require]] name = "mathlib"`)
- `--upstream-namespace = Mathlib` (target-path prefix and post-validate state filter)
- search-root auto-detection via `Mathlib` / `ToMathlib` path components

Without a preset, supply `--upstream-name`, `--upstream-namespace`, and
`--search-root` yourself.

The candidate argument can be a file path (absolute or relative to CWD)
or a dotted Lean module name resolved against `--downstream`.

Subcommands (the workspace becomes dirty by design after `validate`
succeeds):

| Subcommand | What |
|---|---|
| (default) | The full validate workflow (audit + copy + mathlib build + redirect + stub + downstream build). |
| `stage` | Everything `validate` does except the two builds. Use to iterate before paying for a full build. |
| `stage --dry-run` | Sanity check + import audit only. Triages a candidate without touching anything. |
| `build` | Re-run upstream + downstream builds without re-copying anything. |
| `commit` | Stage two PR-ready branches in both repos. |
| `revert` | Undo a stage/validate. |
| `baseline` | Pre-flight: does the downstream build against the local upstream AS-IS? |

Pass `--verbose` (or `-v`) to build-running subcommands (`baseline`, `stage`,
`build`, or the default `validate`) to stream `lake`'s output; otherwise it's
captured and only surfaced if a build fails.

Pass `--replace-imports` to `validate` or `stage` to skip the re-export stub
and instead delete the candidate, rewriting every `import <source-module>` in
the downstream to the upstreamed module. `commit` then commits the workspace
as-is — the flag belongs to whichever command set it up.

See [SCENARIOS.md](SCENARIOS.md) for the full lifecycle and [DEMO.md](DEMO.md)
for a worked example.

## Config: `.upstreamer`

Drop a `.upstreamer` file at the downstream's root. The tool walks upward
from CWD to find it.

For a Mathlib downstream:

```
preset        = mathlib
upstream-path = ../mathlib
```

With this in place, commands shorten to `upstreamer <subcommand> <candidate>`
from anywhere in the repo.

If you don't own the downstream, don't commit `.upstreamer` (it would dirty
the tree and the tool refuses to run dirty). Instead, exclude it with
`echo .upstreamer >> .git/info/exclude`.

For a non-Mathlib upstream:

```
upstream-path      = ../my-upstream
upstream-name      = my-upstream         # the [[require]] dep name
upstream-namespace = MyUpstream          # the namespace prefix
search-root        = MyProject.Staging   # the staging-area namespace
```

You can also use a preset and override individual fields (CLI > config > preset).

Format: `key = value` per line; `#` and `;` are comments; blank lines OK;
unknown keys ignored. Relative paths resolve against the file's directory.

Recognized keys:

| Key | Meaning |
|---|---|
| `preset` | Preset name (currently only `mathlib`) |
| `upstream-path` | Path to the local upstream clone |
| `upstream-name` | Lakefile dep name |
| `upstream-namespace` | Namespace prefix in the upstream |
| `search-root` | Staging-area namespace in the downstream |

## Caveats

- The upstream commit pinned in `lake-manifest.json` may differ from your
  local clone's HEAD; build failures might reflect API drift rather than
  upstreaming readiness. Run `upstreamer baseline` first to confirm the
  downstream still builds against your local upstream as-is.
- Single-file scope only: if the candidate depends on other staging files,
  the tool refuses up front; upstream those first.
- No automated post-commit revert: `commit` prints the exact commands to
  abandon the staged branches; `revert` only handles the pre-commit dirty state.
