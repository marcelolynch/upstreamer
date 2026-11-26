/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
The `baseline` phase. Pre-flight check: does the downstream still build
against the local mathlib *before* we touch anything? If this fails, any
later `validate` downstream-build failure is a property of the local
mathlib (API drift, missing packages, etc.) — not of the candidate file
the user is trying to upstream.

The phase:

  1. Refuses if either working tree is dirty.
  2. Rewrites the downstream's mathlib `[[require]]` to point at the
     local mathlib path (via Hopscotch's `LakefileProcessor.setPathAny`).
  3. Runs `lake update mathlib` and `lake build` in the downstream.
  4. **Always** restores `lakefile.toml` and `lake-manifest.json` from
     git, regardless of whether the build passed.

After step 4 the downstream's Lake state is back in sync with the
manifest — Lake reads path-dependencies directly without replacing
`.lake/packages/<upstream>`, so the original git clone there still
matches the restored manifest's pinned rev. Plain `lake build` works.
-/
import Hopscotch.LakefileProcessor
import Upstreamer.Git
import Upstreamer.Util

namespace Upstreamer.Baseline

structure Options where
  downstream   : String := "."
  upstreamPath : String
  /-- Lakefile dep name (e.g. `"mathlib"`). -/
  upstreamName : String
  /-- Stream `lake` build output live; otherwise captured and only shown on failure. -/
  verbose : Bool := false
  deriving Repr

private def err (s : String) : IO α := throw (IO.userError s)

/-- Restore lakefile.toml + lake-manifest.json (and lakefile.lean if used)
    from git HEAD. Best-effort; failures are reported but not fatal. -/
private def restoreLakefiles (downstreamAbs : System.FilePath) : IO Unit := do
  let _ ← Git.runGit downstreamAbs #["checkout", "--", "lakefile.toml", "lake-manifest.json"]
  let _ ← Git.runGit downstreamAbs #["checkout", "--", "lakefile.lean"]
  pure ()

def run (opts : Options) : IO Unit := do
  let startMs ← IO.monoMsNow
  let downstreamAbs ← IO.FS.realPath opts.downstream
  let upstreamPathAbs    ← IO.FS.realPath opts.upstreamPath
  -- Phase 0: refuse if either tree is dirty.
  unless (← Git.isWorkingTreeClean downstreamAbs) do
    err s!"downstream working tree {downstreamAbs} is dirty; commit or stash first."
  unless (← Git.isWorkingTreeClean upstreamPathAbs) do
    err s!"upstream working tree {upstreamPathAbs} is dirty; commit or stash first."
  IO.println "✓ both working trees clean"
  -- Phase 1: redirect the downstream's upstream dep to the local checkout.
  IO.println s!"→ rewriting `{opts.upstreamName}` dep in {downstreamAbs}'s lakefile to {upstreamPathAbs}"
  Hopscotch.LakefileProcessor.setPathAny downstreamAbs opts.upstreamName upstreamPathAbs.toString
  IO.println s!"→ lake update {opts.upstreamName}  (in {downstreamAbs})"
  let updateCode ← Util.runLake opts.verbose downstreamAbs #["update", opts.upstreamName]
  if updateCode ≠ 0 then
    -- Restore before throwing, so the user isn't left with a broken lakefile.
    restoreLakefiles downstreamAbs
    err s!"`lake update {opts.upstreamName}` failed (exit {updateCode})"
  -- Phase 2: run the downstream build.
  IO.println s!"→ lake build  (in {downstreamAbs})"
  let buildCode ← Util.runLake opts.verbose downstreamAbs #["build"]
  -- Always restore, regardless of build outcome.
  IO.println "→ restoring downstream lakefile + lake-manifest"
  restoreLakefiles downstreamAbs
  let elapsed := (← IO.monoMsNow) - startMs
  if buildCode ≠ 0 then
    IO.println ""
    IO.println "════════════════════════════════════════════════════════"
    IO.println "  ✗ baseline FAILED"
    IO.println "════════════════════════════════════════════════════════"
    IO.println s!"  duration: {elapsed / 1000}s"
    IO.println ""
    IO.println s!"  the downstream does not build against the local `{opts.upstreamName}` AS-IS."
    IO.println "  Any later `validate` downstream-build failure is likely caused by this drift,"
    IO.println "  not by the candidate file. Possible fixes:"
    IO.println s!"    - check out the upstream commit pinned in {downstreamAbs}/lake-manifest.json"
    IO.println s!"      (the rev field for the `{opts.upstreamName}` package)"
    IO.println s!"    - or fix the downstream files that the local `{opts.upstreamName}` API broke"
    IO.println ""
    IO.println s!"RESULT\tstatus=baseline-fail\tduration_ms={elapsed}"
    err s!"baseline `lake build` failed (exit {buildCode})"
  -- Success.
  IO.println ""
  IO.println "════════════════════════════════════════════════════════"
  IO.println "  ✓ baseline OK"
  IO.println "════════════════════════════════════════════════════════"
  IO.println s!"  duration: {elapsed / 1000}s"
  IO.println ""
  IO.println s!"  the downstream builds cleanly against the local `{opts.upstreamName}`."
  IO.println "  any later `validate` failure is a property of the candidate, not of drift."
  IO.println ""
  IO.println s!"RESULT\tstatus=baseline-ok\tduration_ms={elapsed}"

end Upstreamer.Baseline
