# Scenarios

Concrete invocation chains a maintainer might run, ordered from simplest to
most involved. Each scenario shows the intent, the commands, and a short
note on what the workspace looks like after.

Throughout, `…` stands in for path prefixes you'd substitute (e.g.
`~/upstreamer-project`). Both `--downstream X --mathlib Y` are
required; the candidate argument can be a `.lean` path or a dotted module
name.

> **Tip — drop a `.upstreamer` config file** at your downstream project's
> root and you can omit every common flag. The tool walks upward from CWD
> to find it.
>
> For a Mathlib downstream:
>
> ```
> # carleson/.upstreamer
> preset        = mathlib
> upstream-path = ../mathlib-local
> ```
>
> The `mathlib` preset fills in the lakefile dep name (`mathlib`),
> namespace (`Mathlib`), and search-root auto-detection. For non-Mathlib
> upstreams, drop the preset and set `upstream-name`,
> `upstream-namespace`, and `search-root` explicitly.
>
> Every example below shortens to `upstreamer <subcommand> <candidate>`
> when the config is in place. CLI flags still override config values.

---

## Scenario 1 — "Before I do anything, is the local mathlib even compatible?"

Pre-flight. Run this once after pulling new mathlib commits, or whenever
you suspect drift between the downstream's pinned mathlib and your local
checkout.

```bash
# Sanity-checks that the downstream builds against the local mathlib AS-IS.
# Refuses if either tree is dirty. Restores lakefile + manifest no matter what.
upstreamer baseline --downstream /…/carleson --mathlib /…/mathlib-local
```

**End state**: both repos clean. If this fails, *don't* run `validate`
yet — any later downstream-build failure will be drift, not a candidate
problem.

---

## Scenario 2 — "Triage: which of these dashboard candidates are even worth trying?"

Sub-second per file. Useful for sweeping the dashboard's
`ready_to_upstream` list down to the genuinely upstreamable ones.

```bash
# A single candidate:
upstreamer stage Carleson.ToMathlib.MinLayer \
  --downstream /…/carleson --mathlib /…/mathlib-local \
  --dry-run
# →  ~100ms; RESULT line shows target path + collision flag

# Or sweep the whole list:
for f in $(find /…/carleson/Carleson/ToMathlib -name '*.lean'); do
  upstreamer stage "$f" --downstream /…/carleson --mathlib /…/mathlib-local --dry-run \
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
# ~30s–4min depending on how much downstream code transitively depends on the file.
upstreamer Carleson.ToMathlib.MinLayer \
  --downstream /…/carleson --mathlib /…/mathlib-local \
  --target Mathlib/Order/MinLayer.lean

# Workspace is now dirty by design. Stage two PR-ready branches:
upstreamer commit \
  --downstream /…/carleson --mathlib /…/mathlib-local

# Push:
cd /…/mathlib-local && git push -u origin upstream/minlayer
cd /…/carleson      && git push -u origin upstream/minlayer
```

**End state**: both repos on `upstream/minlayer`, two PRs ready to open.

---

## Scenario 4 — "I want to polish the file before paying for builds"

Stage to set up the workspace; iterate with edits + `build` until you're
happy; then commit. This is the right path when you expect to need a few
rounds of editing for naming, generalization, or doc strings — `validate`
would burn the initial build before your first edit anyway.

```bash
# Set up the workspace (no builds, ~3s):
upstreamer stage Carleson.ToMathlib.MinLayer \
  --downstream /…/carleson --mathlib /…/mathlib-local \
  --target Mathlib/Order/MinLayer.lean

# Open the canonical copy in your editor:
$EDITOR /…/mathlib-local/Mathlib/Order/MinLayer.lean

# Re-verify both sides build (~1–4 min):
upstreamer build --downstream /…/carleson --mathlib /…/mathlib-local

# (Edit + build as many times as you like.)

# When happy, stage PR branches:
upstreamer commit \
  --downstream /…/carleson --mathlib /…/mathlib-local
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
upstreamer Carleson.ToMathlib.Data.Real.ConjExponents --replace-imports

# Then commit — no extra flag needed, commit reads the shape from git status.
upstreamer commit
```

If you want to *iterate* on the rewritten state (e.g. fix a consumer
that the rewrite broke), use `stage --replace-imports` instead and
loop with `build`:

```bash
upstreamer stage Carleson.ToMathlib.Data.Real.ConjExponents --replace-imports
upstreamer build     # verifies both sides build
# (edit / re-build as needed)
upstreamer commit
```

The downstream branch's diff lists each consumer that was rewritten
plus the deletion of the staging file. The PR will not build until the
mathlib pin is bumped — which is exactly the workflow we want.

---

## Scenario 6 — "Started something, changed my mind"

```bash
# From a dirty post-stage / post-validate state:
upstreamer revert --downstream /…/carleson --mathlib /…/mathlib-local
```

**End state**: both repos clean. Plain `lake build` works — restoring
the lakefile and manifest is enough; Lake never replaced
`.lake/packages/mathlib` while the path-redirect was in effect.

---

## Scenario 7 — "Audit refused. What now?"

The candidate imports a sibling staging file, so it can't be upstreamed
in isolation. Investigate the dependency and upstream that first.

```bash
upstreamer stage Carleson.ToMathlib.Annulus --dry-run \
  --downstream /…/carleson --mathlib /…/mathlib-local
# → ✗ candidate imports sibling staging files:
#     line 9: Carleson.ToMathlib.Interval
#     upstream those first, then retry.

# OK, try the dependency:
upstreamer stage Carleson.ToMathlib.Interval --dry-run \
  --downstream /…/carleson --mathlib /…/mathlib-local
# → ✓ would stage cleanly

# Upstream Interval first (with --replace-imports so Annulus's `import`
# of it points at the upstreamed module after the pin is bumped):
upstreamer Carleson.ToMathlib.Interval --replace-imports \
  --downstream /…/carleson --mathlib /…/mathlib-local
upstreamer commit \
  --downstream /…/carleson --mathlib /…/mathlib-local
# Push, get it merged. After that — once the downstream's mathlib pin is
# bumped — `Annulus` will pass the audit too.
```

---

## Scenario 8 — "Build failed during `build`, fix and retry"

```bash
upstreamer stage Carleson.ToMathlib.Foo \
  --downstream /…/carleson --mathlib /…/mathlib-local

# Edit the mathlib copy aggressively:
$EDITOR /…/mathlib-local/Mathlib/Foo.lean

upstreamer build --downstream /…/carleson --mathlib /…/mathlib-local
# → ✗ Mathlib/Foo.lean:42:0 — unknown identifier 'badRef'
#     exit 1

# Fix:
$EDITOR /…/mathlib-local/Mathlib/Foo.lean

# Try again — no need to re-stage:
upstreamer build --downstream /…/carleson --mathlib /…/mathlib-local
# → ✓ build successful

upstreamer commit \
  --downstream /…/carleson --mathlib /…/mathlib-local
```

`build` is idempotent and edit-safe — it never re-copies the candidate
or rewrites the lakefile. Your edits to the mathlib copy are preserved.

---

## Scenario 9 — "I have a backlog of candidates A, B, C to upstream"

The tool is single-candidate; cycle through them sequentially.

```bash
# === Candidate A ===
upstreamer Carleson.ToMathlib.A \
  --downstream /…/carleson --mathlib /…/mathlib-local
upstreamer commit \
  --downstream /…/carleson --mathlib /…/mathlib-local

cd /…/mathlib-local && git push -u origin upstream/a
cd /…/carleson      && git push -u origin upstream/a

# Use the exact "to abandon" lines from commit's summary to return to clean
# (the original ref is captured at commit-time so the SHAs / branch names
#  are correct):
cd /…/mathlib-local && git checkout 1a4917a18b && git branch -D upstream/a   # keep the branch live on remote, just not checked out locally
cd /…/carleson      && git checkout master      # branch still exists too if you want to push amends

# === Candidate B ===
upstreamer Carleson.ToMathlib.B …
upstreamer commit …
# (same drill)
```

If you want both sets of commits to land in the same mathlib PR (e.g.
they're closely related), check out the `upstream/a` branch in mathlib
*before* running `validate B` — that way `commit B` will branch *off*
`upstream/a` instead of master, and you'll get a stacked branch.

---

## Scenario 10 — "I committed but want to throw it away without pushing"

`commit` already prints the exact commands; just paste them.

```bash
cd /…/mathlib-local && git checkout 1a4917a18b && git branch -D upstream/foo
cd /…/carleson      && git checkout master      && git branch -D upstream/foo
```

**End state**: both repos clean, no record of the attempt.

---

## Scenario 11 — "Tool was Ctrl-C'd mid-run; what state am I in?"

Inspect first, then choose:

```bash
git -C /…/carleson      status --short
git -C /…/mathlib-local status --short
```

| What you see | What to do |
|---|---|
| Both clean | Nothing to recover. Start fresh. |
| Mathlib has 1 untracked .lean + carleson has 3 modified files | `upstreamer revert …` |
| Mathlib has multiple untracked files, or carleson has unrelated mods | `revert` will refuse — clean up by hand |
| You're on `upstream/<name>` branches | See Scenario 10 (commit-time abandon) |
| Anything else | Hard reset (below) |

### Hard reset

```bash
cd /…/carleson
git checkout master                  # if you ended up on a branch
git checkout . && git clean -fd      # discard untracked + modified
lake update mathlib                  # belt-and-suspenders; usually unnecessary after a clean revert

cd /…/mathlib-local
git checkout 1a4917a18b30…           # (the commit Carleson's manifest pins)
git checkout . && git clean -fd
git branch | grep '^  upstream/' | xargs -r git branch -D
```

---

## Cheat sheet

With a `.upstreamer` in your downstream root, the `…` (which stands for
`--downstream X --mathlib Y`) becomes empty:

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
