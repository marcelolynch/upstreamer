/-
The `build` phase: re-runs the two build phases — building the
upstreamed file inside the upstream, then building the downstream
against it — without re-copying the candidate or re-rewriting the
lakefile. Useful when the user has edited the file in the upstream
checkout and wants to confirm both sides still build.

The candidate path is read from `git status` — no inputs other than the
two repository roots are needed.
-/
import Upstreamer.Git
import Upstreamer.State
import Upstreamer.Util

namespace Upstreamer.Build

structure Options where
  downstream : String := "."
  upstreamPath : String
  /-- Upstream namespace, for state-detection filtering. Default `"Mathlib"`. -/
  upstreamNamespace : String := "Mathlib"
  /-- Stream `lake` build output live; otherwise captured and only shown on failure. -/
  verbose : Bool := false
  deriving Repr

private def err (s : String) : IO α := throw (IO.userError s)

def run (opts : Options) : IO Unit := do
  let startMs ← IO.monoMsNow
  let downstreamAbs ← IO.FS.realPath opts.downstream
  let upstreamPathAbs    ← IO.FS.realPath opts.upstreamPath
  let st ← State.detect downstreamAbs upstreamPathAbs opts.upstreamNamespace
  let some targetModule := Util.pathToModule st.upstreamTargetRel
    | err s!"couldn't derive module name from {st.upstreamTargetRel}"
  IO.println "✓ post-validate state recognized:"
  IO.println s!"    building:                {targetModule}"
  IO.println ""
  -- Upstream build (re-runs validate's `buildUpstream`).
  IO.println s!"→ lake exe cache get  (in {upstreamPathAbs})"
  let cacheCode ← Util.runLake opts.verbose upstreamPathAbs #["exe", "cache", "get"]
  if cacheCode ≠ 0 then
    IO.println s!"⚠ `lake exe cache get` exited {cacheCode}; continuing anyway"
  IO.println s!"→ lake build {targetModule}  (in {upstreamPathAbs})"
  let upstreamCode ← Util.runLake opts.verbose upstreamPathAbs #["build", targetModule]
  if upstreamCode ≠ 0 then
    err s!"`lake build {targetModule}` failed in upstream (exit {upstreamCode})."
  IO.println s!"✓ {targetModule} builds inside upstream"
  -- Downstream build (re-runs validate's `buildDownstream`).
  IO.println s!"→ lake build  (in {downstreamAbs})"
  let dsCode ← Util.runLake opts.verbose downstreamAbs #["build"]
  if dsCode ≠ 0 then
    err s!"downstream `lake build` failed (exit {dsCode})."
  IO.println "✓ downstream builds against the (possibly edited) upstream file"
  let elapsed := (← IO.monoMsNow) - startMs
  IO.println ""
  IO.println "════════════════════════════════════════════════════════"
  IO.println "  ✓ build successful — both sides still happy"
  IO.println "════════════════════════════════════════════════════════"
  IO.println s!"  duration: {elapsed / 1000}s"
  IO.println ""
  IO.println s!"RESULT\tstatus=build-ok\ttarget={targetModule}\tduration_ms={elapsed}"

end Upstreamer.Build
