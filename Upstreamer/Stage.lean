/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
The `stage` phase: runs everything `validate` does except the two builds.

After staging, the workspace is in the **same shape** as a successful
`validate` — candidate copied into mathlib, downstream's mathlib dep
redirected at the local checkout, candidate file replaced with a
re-export stub — but neither build has been confirmed to pass. This is
the right phase to use when you want to iterate on the candidate file
(edits + `build`) before paying for an initial build verification.

With `--dry-run`, only the working-tree-clean check and import audit
run, and the summary reports what *would* happen — no files touched.
This is the right phase to use when triaging a list of candidates (e.g.
the dashboard's `ready_to_upstream`) to weed out the ones that won't
even pass the import audit.
-/
import Upstreamer.Workflow

namespace Upstreamer.Stage

/-- Run the stage phase. Without `dryRun`, performs everything `validate`
    does except the two builds (resolve inputs, audit imports, copy,
    redirect dep, write stub). With `dryRun`, only the working-tree-clean
    check and import audit run — no files are touched. -/
def run (opts : Workflow.Options) (dryRun : Bool := false) : IO Unit := do
  let startMs ← IO.monoMsNow
  let r ← Workflow.resolveInputs opts
  Workflow.auditImports r
  if dryRun then
    let elapsed := (← IO.monoMsNow) - startMs
    IO.println ""
    IO.println "════════════════════════════════════════════════════════"
    IO.println "  ✓ dry-run: candidate would stage cleanly; no files touched"
    IO.println "════════════════════════════════════════════════════════"
    IO.println s!"  source:   {r.sourceModule}"
    IO.println s!"  target:   {r.targetModule}"
    if r.collided then
      IO.println s!"            (target file already exists; would use _Upstreamed suffix)"
    IO.println s!"  duration: {elapsed / 1000}s"
    IO.println ""
    IO.println s!"RESULT\tstatus=stage-dry-run-ok\tsource={r.sourceModule}\ttarget={r.targetModule}\tcollision={r.collided}\tduration_ms={elapsed}"
    return
  Workflow.copyToMathlib r
  Workflow.redirectDependency r
  if opts.replaceImports then Workflow.replaceImports r else Workflow.writeReexportStub r
  let elapsed := (← IO.monoMsNow) - startMs
  IO.println ""
  IO.println "════════════════════════════════════════════════════════"
  IO.println "  ✓ workspace staged — no builds run yet"
  IO.println "════════════════════════════════════════════════════════"
  IO.println s!"  source:   {r.sourceModule}"
  IO.println s!"  target:   {r.targetModule}"
  if r.collided then
    IO.println s!"            (target file already existed; used _Upstreamed suffix)"
  IO.println s!"  duration: {elapsed / 1000}s"
  IO.println ""
  IO.println "  next steps:"
  IO.println s!"    edit {r.upstreamPathAbs}/{r.targetPath} as needed"
  IO.println       "    `upstreamer build`             — verify both sides build"
  IO.println       "    `upstreamer commit`            — stage PR branches"
  IO.println       "    `upstreamer revert`            — abandon"
  IO.println ""
  IO.println s!"RESULT\tstatus=stage-ok\tsource={r.sourceModule}\ttarget={r.targetModule}\tcollision={r.collided}\tduration_ms={elapsed}"

end Upstreamer.Stage
