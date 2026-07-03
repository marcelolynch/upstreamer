# Demo: end-to-end upstreaming with `upstreamer`

A complete walkthrough using [toric](https://github.com/YaelDillies/toric)
(a downstream that stages Mathlib candidates under `Toric/Mathlib/…`) and a
local mathlib clone. Set up `.upstreamer` once, then run every command with
just the candidate name. The tool walks upward from CWD to find the config
and applies its defaults.

## Phase reference

| Phase | What it does | Workspace before → after |
|---|---|---|
| `baseline` | Sanity-check that the downstream still builds against the local upstream AS-IS | clean → clean |
| `stage` | Copy candidate, redirect lakefile, write re-export stub. No builds. | clean → dirty |
| `stage --dry-run` | Phases 0–2 only (sanity + import audit). | clean → clean |
| (default, no subcommand) `validate` | Stage plus both builds, end-to-end | clean → dirty |
| `build` | Re-run upstream build + downstream build only. | dirty → dirty |
| `commit` | Stage two PR-ready branches; downstream lakefile + manifest restored | dirty → on-branches |
| `revert` | Undo everything stage/validate did | dirty → clean |

The key invariant: `commit`, `build`, and `revert` read the workspace
state via `git status` rather than recomputing path mappings — so they
all compose with whatever `stage` or `validate` left behind. Anything
else gets a clean refusal.

## Setup (do once)

The examples assume a workspace laid out as siblings — adjust the paths to
wherever you keep things:

```
~/upstreaming/
├── upstreamer     # this tool
├── toric          # the downstream (github.com/YaelDillies/toric)
└── mathlib        # a local mathlib clone at toric's pinned commit
```

### 1. Build the tool

```bash
cd ~/upstreaming/upstreamer
lake build
```

The bin lands at `./.lake/build/bin/upstreamer`. The examples below use a
bare `upstreamer` — drop one of these into your shell so the rest works
verbatim:

```bash
# Option A: alias for this session.
alias upstreamer=~/upstreaming/upstreamer/.lake/build/bin/upstreamer

# Option B: put the build dir on PATH.
export PATH="$HOME/upstreaming/upstreamer/.lake/build/bin:$PATH"
```

(Avoid `lake exe upstreamer …` — it works but masks the binary's exit
code, which makes scripting awkward.)

### 2. Clone the downstream

```bash
cd ~/upstreaming
git clone https://github.com/YaelDillies/toric.git
git -C toric checkout 39eff375c59f4897d348b2aa88b7a5399839a1c5   # the toric commit this guide was validated against
```

### 3. Align the local mathlib to toric's pinned commit

So API drift doesn't masquerade as upstreaming-readiness failures. The
toric commit above pins its mathlib at `ed585ca0`; check out that exact
commit in your local mathlib clone and prime the olean cache:

```bash
cd ~/upstreaming/mathlib
git checkout ed585ca0f67ec631ea987466127e022c11849b43   # the mathlib commit toric pins at the commit above
lake exe cache get        # downloads ~8.6k prebuilt Mathlib oleans
```

(To follow along with a newer toric instead, drop the two `checkout`s and
read toric's current mathlib pin from `toric/lake-manifest.json`.)

`upstreamer baseline` (below) confirms this worked.

### 4. Drop a `.upstreamer` in toric

Save this config file to make every later command short. Save as
`~/upstreaming/toric/.upstreamer`:

```ini
# toric upstreamer config.

# The `mathlib` preset wires up the well-known values for projects that
# upstream to leanprover-community/mathlib4:
#   - upstream-name      = mathlib   (the [[require]] dep name in lakefile.toml)
#   - upstream-namespace = Mathlib   (target-path prefix and state-detection filter)
#   - search-root auto-detection via "Mathlib" / "ToMathlib" path segments
#     (here, `Toric.Mathlib` is detected from the `Mathlib` segment)
preset = mathlib

# Filesystem path to the local mathlib clone. Relative paths are
# resolved against this file's directory.
upstream-path = ../mathlib
```

Two lines (plus comments) is everything the tool needs; the rest comes
from the preset.

Keep the config out of git. `.upstreamer` is an untracked file, so it makes toric's working tree "dirty", and the tool refuses to run on a dirty tree. Since toric isn't your repo, don't commit it — exclude it locally:

```bash
echo ".upstreamer" >> ~/upstreaming/toric/.git/info/exclude
```

(In your own downstream, add `.upstreamer` to the tracked `.gitignore` and commit that.)

A non-Mathlib project would write:

```ini
upstream-path      = ../my-upstream
upstream-name      = my-upstream
upstream-namespace = MyUpstream
search-root        = MyProject.Staging
```

Both repos must be clean before each tool invocation. The tool refuses otherwise.

## Walkthrough

Every command below assumes you're somewhere inside the toric repo (the
config walk-up handles the rest). The candidate argument can be a file
path or a dotted module name.

### 0. `baseline` — does the downstream even build against this mathlib?

```bash
cd ~/upstreaming/toric
upstreamer baseline
```

```
✓ both working trees clean
→ rewriting `mathlib` dep in …/toric's lakefile to …/mathlib
→ lake update mathlib  (in …/toric)
→ lake build  (in …/toric)
→ restoring downstream lakefile + lake-manifest
  ✓ baseline OK
  duration: 78s
RESULT	status=baseline-ok	duration_ms=78683
```

- Refuses if either tree is dirty.
- Redirects the lakefile, runs `lake build` in toric, restores the lakefile.
- ~80s on a primed cache (toric is small; it's mostly compiling toric's
  own files against the cached mathlib).
- If this fails, *do not proceed*: any later downstream-build failure
  will be upstream API drift, not the candidate's fault.

### 1. `stage --dry-run` — triage candidates

Sub-second per file. Sweep the whole staging area:

```bash
for f in $(find Toric/Mathlib -name '*.lean'); do
  upstreamer stage "$f" --dry-run 2>&1 | grep -E '^(RESULT|✗|upstreamer)' | head -1
done
```

A clean candidate reports its target and whether it collides with an
existing Mathlib file:

```
✓ candidate imports look clean (1 import lines audited)
  ✓ dry-run: candidate would stage cleanly; no files touched
    source:   Toric.Mathlib.LinearAlgebra.Finsupp.LinearCombination
    target:   Mathlib.LinearAlgebra.Finsupp.LinearCombination_Upstreamed
              (target file already exists; would use _Upstreamed suffix)
RESULT	status=stage-dry-run-ok	source=…	target=…_Upstreamed	collision=true	duration_ms=642
```

A candidate that imports a sibling staging file is refused up front:

```
✗ candidate imports sibling staging files:
    line 11: Toric.Mathlib.RingTheory.Bialgebra.TensorProduct
  upstream those first, then retry.
upstreamer stage: import audit failed
```

Note: `collision=true` is the common case here. toric stages files at `Toric/Mathlib/<mathlib-path>`, extending existing Mathlib modules (each candidate `public import`s the same-named `Mathlib.…` file). The target path usually already exists, so the tool copies to a `…_Upstreamed.lean` sibling rather than clobbering it. You merge the two by hand before opening the real PR. A downstream that stages brand-new files (no matching Mathlib path) gets `collision=false` and no suffix.

### 2. `stage` — set up the workspace, no builds

```bash
upstreamer stage Toric.Mathlib.LinearAlgebra.Finsupp.LinearCombination
```

About 5 seconds (file copy + `lake update mathlib`). Workspace ends in the
same shape `validate` would produce, but nothing is verified to build.
The summary tells you the canonical mathlib path so you can start editing.

### 3. Edit + `build` — iterate

Open the copy in your local mathlib
(`…/mathlib/Mathlib/LinearAlgebra/Finsupp/LinearCombination_Upstreamed.lean`)
and polish: fix docstrings, generalize, follow Mathlib's naming. To verify
both sides still build:

```bash
upstreamer build
```

`build` re-runs only the two build phases — `lake build <module>` in
mathlib and then `lake build` in toric. Reads the candidate's path from
`git status`, so no candidate argument needed.

If you broke something, exits 1 and surfaces the build error. Fix and
retry. Iterate until happy.

### 4a. `commit` — happy path: stage PR branches

```bash
upstreamer commit
```

```
→ upstream: creating branch 'upstream/linearcombination' and committing …_Upstreamed.lean
✓ upstream branch 'upstream/linearcombination' has 1 commit
→ downstream: reverting lakefile + manifest, creating branch 'upstream/linearcombination'
✓ downstream branch 'upstream/linearcombination' has 1 commit
  ✓ branches staged for two interrelated PRs

  next steps:
    1. cd …/mathlib && git push -u origin upstream/linearcombination
    2. cd …/toric   && git push -u origin upstream/linearcombination

  to abandon these branches and return to the previous state:
    cd …/mathlib && git checkout ed585ca0f6 && git branch -D upstream/linearcombination
    cd …/toric   && git checkout 39eff37    && git branch -D upstream/linearcombination

  ⚠ collision: the upstream branch contains a `_Upstreamed.lean` file.
    Before opening the upstream PR, manually merge it with the existing
    file at the un-suffixed path, and amend the commit (`git commit --amend`).
```

The original ref is captured before the branch is created, so the abandon
line is exact. On a collision the upstream commit holds the `_Upstreamed`
file — merge it into the real module and `git commit --amend` before you
push.

For a more invasive downstream diff that deletes the staging file and
rewrites all consumer imports, pass `--replace-imports` to `validate`
(or to `stage`, then `build` to verify, then `commit`). The flag belongs
to whatever sets up the workspace; `commit` just commits whatever shape
it finds.

### 4b. `revert` — abandon and return to clean

```bash
upstreamer revert
```

```
→ upstream: removing …_Upstreamed.lean
→ downstream: restoring lakefile.toml, lake-manifest.json, candidate
✓ workspace reverted to pre-validate state
RESULT	status=revert-ok	…	mode=stub
```

Removes the untracked mathlib file (and any empty parent directories);
`git checkout`s the modified tracked files. Both repos clean, plain
`lake build` works — Lake's state is back in sync with the restored
manifest.

## All reasonable invocation chains

- `baseline` — clean → clean
- `stage --dry-run` — clean → clean (~0.5s)
- `stage` → `revert` — clean → dirty → clean
- `stage` → `build` → `revert` — build verifies, revert cleans
- `stage` → `commit` — stage+commit without build verification (commit succeeds regardless; you've signed off on it)
- `stage` → `build` → `commit` — recommended for cautious iteration
- `validate` → `revert`
- `validate` → `commit`
- `validate` → `build` (after edit) → `commit`
- `baseline` → any of the above — baseline restores everything before exiting

### Where lakefiles get reverted

- `baseline`: rewrites lakefile, restores it (always, even on failure).
- `stage`: rewrites lakefile, leaves it redirected.
- `validate`: same as stage but also runs builds.
- `build`: doesn't touch the lakefile.
- `commit`: explicitly restores lakefile + manifest as part of creating the downstream branch, so the toric PR's diff contains only candidate-related changes, not infrastructure.
- `revert`: explicitly restores lakefile + manifest.

Lakefile cleanup happens at exactly two end-points: `commit` and `revert`. Both subcommands own the full transition out of the dirty state.

### Refusals

| Invocation | Outcome |
|---|---|
| `stage` from dirty | ✓ refused, "downstream working tree dirty" |
| `validate` from dirty | ✓ refused |
| `baseline` from dirty | ✓ refused |
| `commit` from clean | ✓ refused, "no untracked .lean file under mathlib's Mathlib/" |
| `revert` from clean | ✓ refused |
| `build` from clean | ✓ refused |
| candidate imports a sibling staging file | ✓ refused, "import audit failed" |

### After commit: the BRANCHED state

`commit` leaves both repos on `upstream/<name>` branches. From there:

- Push and open PRs: use the `git push -u origin upstream/<name>` lines from the commit summary.
- Abandon: use the `git checkout … && git branch -D upstream/<name>` lines. The original ref is captured at commit-time so the commands are exact.
- Iterate further: edit on the branch, `git commit --amend` or add new commits, force-push.
- Move to the next candidate: abandon (or push) first, then start a new `validate`/`stage` cycle. The tool refuses to run a fresh stage/validate while in BRANCHED state because the working tree is technically "clean" but starting a new stage on top of `upstream/<old>` would entangle them.

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
# toric
cd ~/upstreaming/toric
git checkout 39eff375c59f4897d348b2aa88b7a5399839a1c5 && git checkout . && git clean -fd && lake update mathlib

# mathlib  (re-check-out toric's pinned commit)
cd ~/upstreaming/mathlib
git checkout ed585ca0f67ec631ea987466127e022c11849b43
git checkout . && git clean -fd
git branch | grep '^  upstream/' | xargs -r git branch -D
```
