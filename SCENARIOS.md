# Scenarios

Concrete invocation chains a maintainer might run, ordered from simplest to
most involved. Each scenario shows the intent, the commands, and a short
note on what the workspace looks like after. The running example is
[toric](https://github.com/YaelDillies/toric), which stages Mathlib
candidates under `Toric/Mathlib/…`.

Throughout, `…` stands in for path prefixes you'd substitute (e.g.
`~/upstreamer-project`). Without a config file, both
`--downstream <path> --upstream-path <path>` are required; the candidate
argument can be a `.lean` path or a dotted module name.

> **Tip — drop a `.upstreamer` config file** at your downstream project's
> root and you can omit every common flag. The tool walks upward from CWD
> to find it.
>
> For a Mathlib downstream:
>
> ```
> # toric/.upstreamer
> preset        = mathlib
> upstream-path = ../mathlib
> ```
>
> The `mathlib` preset fills in the lakefile dep name (`mathlib`),
> namespace (`Mathlib`), and search-root auto-detection (here
> `Toric.Mathlib`, from the `Mathlib` path segment). For non-Mathlib
> upstreams, drop the preset and set `upstream-name`,
> `upstream-namespace`, and `search-root` explicitly.
>
> Every example below shortens to `upstreamer <subcommand> <candidate>`
> when the config is in place. CLI flags still override config values.
>
> If toric isn't your repo, don't commit `.upstreamer` (it would dirty the
> tree and the tool refuses to run dirty). Exclude it locally:
> `echo .upstreamer >> .git/info/exclude`.

> **Note — collisions are the common case with toric.** Its candidates
> live at `Toric/Mathlib/<mathlib-path>` and *extend existing* Mathlib
> modules, so the target file usually already exists. The tool then copies
> to a `…_Upstreamed.lean` sibling (`collision=true`) and you merge by hand
> before the real PR. A downstream that stages brand-new files gets
> `collision=false` and no suffix.

---

## Scenario 1 — "Before I do anything, is the local mathlib even compatible?"

Pre-flight. Run this once after pulling new mathlib commits, or whenever
you suspect drift between the downstream's pinned mathlib and your local
checkout.

```bash
# Sanity-checks that the downstream builds against the local mathlib AS-IS.
# Refuses if either tree is dirty. Restores lakefile + manifest no matter what.
upstreamer baseline --downstream …/toric --upstream-path …/mathlib
```

**End state**: both repos clean. If this fails, *don't* run `validate`
yet — any later downstream-build failure will be drift, not a candidate
problem.

---

## Scenario 2 — "Triage: which of these dashboard candidates are even worth trying?"

Sub-second per file. Useful for sweeping the staging area down to the
genuinely upstreamable ones.

```bash
# A single candidate:
upstreamer stage Toric.Mathlib.LinearAlgebra.Finsupp.LinearCombination \
  --downstream …/toric --upstream-path …/mathlib \
  --dry-run
# →  ~0.5s; RESULT line shows target path + collision flag

# Or sweep the whole staging area:
for f in $(find …/toric/Toric/Mathlib -name '*.lean'); do
  upstreamer stage "$f" --downstream …/toric --upstream-path …/mathlib --dry-run \
    2>&1 | grep -E '^(RESULT|✗|upstreamer)' | head -1
done
```

**End state**: both repos untouched. Files with sibling-staging-area
imports surface as `import audit failed`; the rest emit
`status=stage-dry-run-ok`.

---

## Scenario 3 — "I'm confident in this candidate. Run the whole thing."

The classic happy path: validate end-to-end, then commit.

```bash
# Full validate: sanity, audit, copy, mathlib build, redirect, stub, downstream build.
# ~20s–several min depending on how much downstream code transitively depends on the file.
upstreamer Toric.Mathlib.LinearAlgebra.Finsupp.LinearCombination \
  --downstream …/toric --upstream-path …/mathlib

# Workspace is now dirty by design. Stage two PR-ready branches:
upstreamer commit \
  --downstream …/toric --upstream-path …/mathlib

# On a collision, the upstream commit holds a `_Upstreamed.lean` file —
# merge it into the existing module and `git commit --amend` before pushing.

# Push:
cd …/mathlib && git push -u origin upstream/linearcombination
cd …/toric   && git push -u origin upstream/linearcombination
```

**End state**: both repos on `upstream/linearcombination`, two PRs ready to open.

---

## Scenario 4 — "I want to polish the file before paying for builds"

Stage to set up the workspace; iterate with edits + `build` until you're
happy; then commit. This is the right path when you expect to need a few
rounds of editing for naming, generalization, or doc strings — `validate`
would burn the initial build before your first edit anyway.

```bash
# Set up the workspace (no builds, ~5s):
upstreamer stage Toric.Mathlib.Algebra.Polynomial.Bivariate \
  --downstream …/toric --upstream-path …/mathlib

# Open the canonical copy in your editor (note the _Upstreamed suffix on a collision):
$EDITOR …/mathlib/Mathlib/Algebra/Polynomial/Bivariate_Upstreamed.lean

# Re-verify both sides build:
upstreamer build --downstream …/toric --upstream-path …/mathlib

# (Edit + build as many times as you like.)

# When happy, stage PR branches:
upstreamer commit \
  --downstream …/toric --upstream-path …/mathlib
```

**End state**: same as Scenario 3.

---

## Scenario 5 — "I want a clean migration in the downstream PR, not a stub"

By default the downstream gets a 3-line re-export stub at the staging
file — small diff, but the file lingers. With `--replace-imports` on
`validate` (or on `stage`), the staging file is deleted and every
consumer's `import` is rewritten to point at the upstreamed module
instead. `commit` then commits whatever shape the workspace is in.

```bash
# Validate with the aggressive cleanup mode (workspace ends with the
# candidate deleted + every consumer's `import` rewritten).
upstreamer Toric.Mathlib.RingTheory.TensorProduct.Maps --replace-imports

# Then commit — no extra flag needed, commit reads the shape from git status.
upstreamer commit
```

If you want to *iterate* on the rewritten state (e.g. fix a consumer
that the rewrite broke), use `stage --replace-imports` instead and
loop with `build`:

```bash
upstreamer stage Toric.Mathlib.RingTheory.TensorProduct.Maps --replace-imports
upstreamer build     # verifies both sides build
# (edit / re-build as needed)
upstreamer commit
```

The downstream branch's diff lists each consumer that was rewritten
plus the deletion of the staging file. The PR will not build until the
mathlib pin is bumped — which is exactly the workflow we want. (On a
collision, imports are rewritten to the `_Upstreamed` module; rename to
the final path once you've merged the upstream file.)

---

## Scenario 6 — "Started something, changed my mind"

```bash
# From a dirty post-stage / post-validate state:
upstreamer revert --downstream …/toric --upstream-path …/mathlib
```

**End state**: both repos clean. Plain `lake build` works — restoring
the lakefile and manifest is enough; Lake never replaced
`.lake/packages/mathlib` while the path-redirect was in effect.

---

## Scenario 7 — "Audit refused. What now?"

The candidate imports a sibling staging file, so it can't be upstreamed
in isolation. Investigate the dependency and upstream that first. toric
has a real chain: `AlgebraicGeometry.Group.Affine` depends on
`RingTheory.Bialgebra.TensorProduct`, which depends on
`RingTheory.TensorProduct.Maps` (clean).

```bash
upstreamer stage Toric.Mathlib.AlgebraicGeometry.Group.Affine --dry-run \
  --downstream …/toric --upstream-path …/mathlib
# → ✗ candidate imports sibling staging files:
#     line 11: Toric.Mathlib.RingTheory.Bialgebra.TensorProduct
#     upstream those first, then retry.

# Follow the chain down:
upstreamer stage Toric.Mathlib.RingTheory.Bialgebra.TensorProduct --dry-run \
  --downstream …/toric --upstream-path …/mathlib
# → ✗ imports sibling: line 4: Toric.Mathlib.RingTheory.TensorProduct.Maps

upstreamer stage Toric.Mathlib.RingTheory.TensorProduct.Maps --dry-run \
  --downstream …/toric --upstream-path …/mathlib
# → ✓ would stage cleanly

# Upstream the leaf first (with --replace-imports so the sibling's `import`
# of it points at the upstreamed module after the pin is bumped):
upstreamer Toric.Mathlib.RingTheory.TensorProduct.Maps --replace-imports \
  --downstream …/toric --upstream-path …/mathlib
upstreamer commit \
  --downstream …/toric --upstream-path …/mathlib
# Push, get it merged. Then — once the downstream's mathlib pin is bumped —
# `Bialgebra.TensorProduct` passes the audit, then `Affine` after that.
```

---

## Scenario 8 — "Build failed during `build`, fix and retry"

```bash
upstreamer stage Toric.Mathlib.RingTheory.TensorProduct.Maps \
  --downstream …/toric --upstream-path …/mathlib

# Edit the mathlib copy aggressively:
$EDITOR …/mathlib/Mathlib/RingTheory/TensorProduct/Maps_Upstreamed.lean

upstreamer build --downstream …/toric --upstream-path …/mathlib
# → ✗ Mathlib/RingTheory/TensorProduct/Maps_Upstreamed.lean:42:0 — unknown identifier 'badRef'
#     exit 1

# Fix:
$EDITOR …/mathlib/Mathlib/RingTheory/TensorProduct/Maps_Upstreamed.lean

# Try again — no need to re-stage:
upstreamer build --downstream …/toric --upstream-path …/mathlib
# → ✓ build successful

upstreamer commit \
  --downstream …/toric --upstream-path …/mathlib
```

`build` is idempotent and edit-safe — it never re-copies the candidate
or rewrites the lakefile. Your edits to the mathlib copy are preserved.

---

## Scenario 9 — "I have a backlog of candidates A, B, C to upstream"

The tool is single-candidate; cycle through them sequentially.

```bash
# === Candidate A ===
upstreamer Toric.Mathlib.LinearAlgebra.Finsupp.LinearCombination \
  --downstream …/toric --upstream-path …/mathlib
upstreamer commit \
  --downstream …/toric --upstream-path …/mathlib

cd …/mathlib && git push -u origin upstream/linearcombination
cd …/toric   && git push -u origin upstream/linearcombination

# Use the exact "to abandon" lines from commit's summary to return to clean
# (the original ref is captured at commit-time so the SHAs / branch names
#  are correct):
cd …/mathlib && git checkout <pin>  && git branch -D upstream/linearcombination  # keep the branch live on remote, just not checked out locally
cd …/toric   && git checkout master # branch still exists too if you want to push amends

# === Candidate B ===
upstreamer Toric.Mathlib.Algebra.Polynomial.Bivariate …
upstreamer commit …
# (same drill)
```

If you want both sets of commits to land in the same mathlib PR (e.g.
they're closely related), check out the first `upstream/…` branch in
mathlib *before* running the next `validate` — that way the next `commit`
will branch *off* it instead of the pinned commit, and you'll get a
stacked branch.

---

## Scenario 10 — "I committed but want to throw it away without pushing"

`commit` already prints the exact commands; just paste them.

```bash
cd …/mathlib && git checkout <pin>  && git branch -D upstream/foo
cd …/toric   && git checkout master && git branch -D upstream/foo
```

**End state**: both repos clean, no record of the attempt.

---

## Scenario 11 — "Tool was Ctrl-C'd mid-run; what state am I in?"

Inspect first, then choose:

```bash
git -C …/toric   status --short
git -C …/mathlib status --short
```

| What you see | What to do |
|---|---|
| Both clean | Nothing to recover. Start fresh. |
| Mathlib has 1 untracked .lean + toric has modified files | `upstreamer revert …` |
| Mathlib has multiple untracked files, or toric has unrelated mods | `revert` will refuse — clean up by hand |
| You're on `upstream/<name>` branches | See Scenario 10 (commit-time abandon) |
| Anything else | Hard reset (below) |

### Hard reset

```bash
cd …/toric
git checkout master                  # if you ended up on a branch
git checkout . && git clean -fd      # discard untracked + modified
lake update mathlib                  # belt-and-suspenders; usually unnecessary after a clean revert

cd …/mathlib
git checkout <pin>                   # the commit toric's manifest pins
git checkout . && git clean -fd
git branch | grep '^  upstream/' | xargs -r git branch -D
```

---

## Cheat sheet

With a `.upstreamer` in your downstream root, the `…` (which stands for
`--downstream <path> --upstream-path <path>`) becomes empty:

| You want to... | Run |
|---|---|
| Confirm local mathlib isn't drifted | `upstreamer baseline` |
| Triage one or more candidates | `upstreamer stage <c> --dry-run` |
| Set up workspace, no builds | `upstreamer stage <c>` |
| Validate a single candidate end-to-end | `upstreamer <c>` |
| Re-verify after editing in mathlib | `upstreamer build` |
| Stage two PR branches (stub stays) | `upstreamer commit` |
| Validate with delete + rewrite (no stub) | `upstreamer <c> --replace-imports` |
| Abandon a stage/validate | `upstreamer revert` |
| Abandon committed branches | use the lines `commit` printed |

Every invocation ends with a tab-separated `RESULT  …` line — grep for it.
