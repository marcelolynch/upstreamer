# Demo: end-to-end upstreaming with `upstreamer`

A complete walkthrough using Carleson + a local mathlib clone. The trick
is to **set up `.upstreamer` once** and then run every command with
nothing but the candidate name. The tool walks upward from CWD to find
the config and applies its defaults.

## Phase reference

| Phase | What it does | Workspace before → after |
|---|---|---|
| `baseline` | Sanity-check that the downstream still builds against the local upstream AS-IS | clean → clean |
| `stage` | Copy candidate, redirect lakefile, write re-export stub. **No builds.** | clean → dirty |
| `stage --dry-run` | Phases 0–2 only (sanity + import audit). | clean → clean |
| (default, no subcommand) `validate` | Stage **plus** both builds, end-to-end | clean → dirty |
| `build` | Re-run upstream build + downstream build only. | dirty → dirty |
| `commit` | Stage two PR-ready branches; downstream lakefile + manifest restored | dirty → on-branches |
| `revert` | Undo everything stage/validate did | dirty → clean |

The key invariant: `commit`, `build`, and `revert` read the workspace
state via `git status` rather than recomputing path mappings — so they
all compose with whatever `stage` or `validate` left behind. Anything
else gets a clean refusal.

---

## Setup (do once)

### 1. Build the tool

```bash
cd ~/upstreamer-project/upstreamer
lake build
```

The bin lands at `./.lake/build/bin/upstreamer`. The examples below use a
bare `upstreamer` — drop one of these into your shell so the rest works
verbatim:

```bash
# Option A: alias for this session.
alias upstreamer=~/upstreamer-project/upstreamer/.lake/build/bin/upstreamer

# Option B: put the build dir on PATH.
export PATH="~/upstreamer-project/upstreamer/.lake/build/bin:$PATH"
```

(Avoid `lake exe upstreamer …` — it works but masks the binary's exit
code, which makes scripting awkward.)

### 2. Align the local mathlib to Carleson's pinned commit

So API drift doesn't masquerade as upstreaming-readiness failures:

```bash
cd ~/upstreamer-project/mathlib-local
git fetch upstream 1a4917a18b30ea1333c195e597067fe044ac9176
git checkout 1a4917a18b30ea1333c195e597067fe044ac9176
lake exe cache get        # primes ~7.6k Mathlib oleans
```

### 3. Drop a `.upstreamer` in Carleson

This is the magic that makes every later command short. Save as
`~/upstreamer-project/carleson/.upstreamer`:

```ini
# Carleson upstreamer config.

# The `mathlib` preset wires up the well-known values for projects that
# upstream to leanprover-community/mathlib4:
#   - upstream-name      = mathlib   (the [[require]] dep name in lakefile.toml)
#   - upstream-namespace = Mathlib   (target-path prefix and state-detection filter)
#   - search-root auto-detection via "Mathlib" / "ToMathlib" path segments
preset = mathlib

# Filesystem path to the local mathlib4 clone. Relative paths are
# resolved against this file's directory.
upstream-path = ../mathlib-local
```

Two lines (plus comments) is everything the tool needs; the rest comes
from the preset.

A non-Mathlib project would write:

```ini
upstream-path      = ../my-upstream
upstream-name      = my-upstream
upstream-namespace = MyUpstream
search-root        = MyProject.Staging
```

Both repos must be **clean** before each tool invocation. The tool
refuses otherwise.

---

## Walkthrough

Every command below assumes you're somewhere inside the carleson repo (the
config walk-up handles the rest). The candidate argument can be a file
path or a dotted module name.

### 0. `baseline` — does the downstream even build against this mathlib?

```bash
cd ~/upstreamer-project/carleson
upstreamer baseline
```

- Refuses if either tree is dirty.
- Redirects lakefile, runs `lake build` in carleson, restores lakefile.
- ~40s on a primed cache.
- If this fails, *do not proceed*: any later downstream-build failure
  will be upstream API drift, not the candidate's fault.

### 1. `stage --dry-run` — triage candidates

Sub-second per file. Sweep the dashboard's `ready_to_upstream` list:

```bash
for f in $(find Carleson/ToMathlib -name '*.lean'); do
  upstreamer stage "$f" --dry-run 2>&1 | grep -E '^(RESULT|✗|upstreamer)' | head -1
done
```

Each `RESULT` line tells you the target path and whether there's a
collision. Files that import sibling staging modules surface as
`import audit failed` and don't make it to staging.

### 2. `stage` — set up the workspace, no builds

```bash
upstreamer stage Carleson.ToMathlib.MinLayer --target Mathlib/Order/MinLayer.lean
```

About 3 seconds (file copy + `lake update mathlib`). Workspace ends in
the same shape `validate` would produce, but **nothing is verified to
build**. The summary tells you the canonical mathlib path so you can
start editing.

### 3. Edit + `build` — iterate

Open `/…/mathlib-local/Mathlib/Order/MinLayer.lean` and polish: fix
docstrings, generalize, follow Mathlib's naming. To verify both sides
still build:

```bash
upstreamer build
```

`build` re-runs only the two build phases — `lake build <module>` in
mathlib and then `lake build` in carleson. Reads the candidate's path
from `git status`, so no candidate argument needed.

If you broke something, exits 1 and surfaces the build error. Fix and
retry. Iterate until happy.

### 4a. `commit` — happy path: stage PR branches

```bash
upstreamer commit
```

The summary shows the exact next-step commands:

```
  next steps:
    1. cd /…/mathlib-local && git push -u origin upstream/minlayer
    2. cd /…/carleson      && git push -u origin upstream/minlayer

  to abandon these branches and return to the previous state:
    cd /…/mathlib-local && git checkout 1a4917a18b && git branch -D upstream/minlayer
    cd /…/carleson      && git checkout master      && git branch -D upstream/minlayer
```

The original ref is captured before the branch is created, so the
abandon line is exact.

For a more invasive downstream diff that deletes the staging file and
rewrites all consumer imports, pass `--replace-imports` to `validate`
(or to `stage`, then `build` to verify, then `commit`). The flag
belongs to whatever sets up the workspace; `commit` just commits
whatever shape it finds.

### 4b. `revert` — abandon and return to clean

```bash
upstreamer revert
```

Removes the untracked mathlib file (and any empty parent directories);
`git checkout`s the three modified tracked files. Both repos clean,
plain `lake build` works — Lake's state is back in sync with the
restored manifest.

---

## All reasonable invocation chains

| Chain | Outcome |
|---|---|
| `baseline` | ✓ clean → clean |
| `stage --dry-run` | ✓ clean → clean (~60ms) |
| `stage` → `revert` | ✓ clean → dirty → clean |
| `stage` → `build` → `revert` | ✓ build verifies, revert cleans |
| `stage` → `commit` | ✓ stage+commit (no build verification) — **commit succeeds even without verification**; you've signed off on it |
| `stage` → `build` → `commit` | ✓ — recommended path for cautious iteration |
| `validate` → `revert` | ✓ |
| `validate` → `commit` | ✓ |
| `validate` → `build` (after edit) → `commit` | ✓ |
| `baseline` → any of the above | ✓ baseline restores everything before exiting |

### Where lakefiles get reverted

- `baseline`: rewrites lakefile, restores it (always, even on failure).
- `stage`: rewrites lakefile, **leaves it redirected**.
- `validate`: same as stage but also runs builds.
- `build`: doesn't touch the lakefile.
- `commit`: explicitly restores lakefile + manifest as part of creating
  the downstream branch — so the carleson PR's diff is **only the
  candidate-related changes**, not infrastructure.
- `revert`: explicitly restores lakefile + manifest.

Lakefile cleanup happens at exactly two end-points: `commit` and
`revert`. Both subcommands own the full transition out of the dirty state.

### Refusals

| Invocation | Outcome |
|---|---|
| `stage` from dirty | ✓ refused, "downstream working tree dirty" |
| `validate` from dirty | ✓ refused |
| `baseline` from dirty | ✓ refused |
| `commit` from clean | ✓ refused, "no untracked .lean file under mathlib's Mathlib/" |
| `revert` from clean | ✓ refused |
| `build` from clean | ✓ refused |

### After commit: the BRANCHED state

`commit` leaves both repos on `upstream/<name>` branches. From there:

- **Push and open PRs**: use the `git push -u origin upstream/<name>`
  lines from the commit summary.
- **Abandon**: use the `git checkout … && git branch -D upstream/<name>`
  lines. The original ref is captured at commit-time so the commands
  are exact.
- **Iterate further**: edit on the branch, `git commit --amend` or add
  new commits, force-push.
- **Move to the next candidate**: abandon (or push) first, then start a
  new `validate`/`stage` cycle. The tool refuses to run a fresh
  stage/validate while in BRANCHED state because the working tree is
  technically "clean" but starting a new stage on top of `upstream/<old>`
  would entangle them.

---

## Quick reference

With `.upstreamer` in place, every command shortens to:

| Goal | Command |
|---|---|
| Confirm local upstream isn't drifted | `upstreamer baseline` |
| Triage a list of candidates | `upstreamer stage <c> --dry-run` |
| Set up workspace, no builds | `upstreamer stage <c>` |
| Validate end-to-end | `upstreamer <c>` |
| Validate, override target path | `upstreamer <c> --target Mathlib/Order/Foo.lean` |
| Re-verify after editing in mathlib | `upstreamer build` |
| Stage two PR branches (stub stays) | `upstreamer commit` |
| Validate with delete + rewrite (no stub) | `upstreamer <c> --replace-imports` |
| Custom branch name | `… --branch upstream/foo-bar` |
| Abandon a stage/validate | `upstreamer revert` |
| Abandon committed branches | use the exact `git checkout … && git branch -D …` lines `commit` printed |

Every invocation ends with a tab-separated `RESULT  …` line — grep for it.

To override any preset/config value on a single invocation, just add
the corresponding flag (e.g. `--upstream-path /elsewhere`).

## Hard-reset escape hatch

If something goes really wrong (interrupted run, manual edits, stuck on
PR branches and confused):

```bash
# Carleson
cd /…/carleson
git checkout master && git checkout . && git clean -fd && lake update mathlib

# mathlib-local
cd /…/mathlib-local
git checkout 1a4917a18b30ea1333c195e597067fe044ac9176
git checkout . && git clean -fd
git branch | grep '^  upstream/' | xargs -r git branch -D
```
