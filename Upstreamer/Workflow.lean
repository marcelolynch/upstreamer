/-
The end-to-end upstreaming workflow. Each phase from the design plan is its
own def; `run` chains them and surfaces failure modes with clear messages.
-/
import Lean.Data.Json
import Hopscotch.LakefileProcessor
import Upstreamer.Git
import Upstreamer.ImportScan
import Upstreamer.Util

open Lean (Json)
open Upstreamer.ImportScan Upstreamer.Util

namespace Upstreamer.Workflow

/-- Inputs to a single upstreaming run. Built by `Upstreamer.CLI` from the
    parsed command line. -/
structure Options where
  /-- Path to the candidate `.lean` file (absolute or relative to CWD). -/
  candidate     : String
  /-- Path to the downstream project root. Default: ".". -/
  downstream    : String := "."
  /-- Path to the local mathlib clone. Required. -/
  mathlib       : String
  /-- Optional override of the destination path inside mathlib (e.g.
      `"Mathlib/Order/MinLayer.lean"`). -/
  target        : Option String := none
  /-- Optional override of the staging-area namespace (e.g.
      `"Carleson.ToMathlib"`). When omitted, auto-detected from the candidate's
      path components. -/
  searchRoot    : Option String := none
  /-- Skip the dirty-tree refusal (escape hatch for testing). -/
  noVerifyClean : Bool := false
  /-- Stop after the path-mapping & import-audit phases. Reports the target
      path, target module, collision status, and exits 0 without touching any
      files. Useful for batch sanity checks across many candidates. -/
  dryRun        : Bool := false
  deriving Repr

/-- The fully-resolved configuration after Phase 0. -/
structure Resolved where
  /-- Absolute path to the candidate. -/
  candidateAbs       : System.FilePath
  /-- Absolute path to the downstream root. -/
  downstreamAbs      : System.FilePath
  /-- Absolute path to the local mathlib clone. -/
  mathlibAbs         : System.FilePath
  /-- Path components of the candidate relative to `downstreamAbs`. -/
  candRelToDownstream : List String
  /-- Project name as it appears in import statements (path-derived, e.g. "Carleson"). -/
  projectName        : String
  /-- Staging-area namespace, e.g. "Carleson.ToMathlib". -/
  searchRoot         : String
  /-- Path components of the candidate relative to the search root. -/
  candRelToSearchRoot : List String
  /-- Source module name in the downstream, e.g. "Carleson.ToMathlib.MinLayer". -/
  sourceModule       : String
  /-- Target path inside mathlib (relative), e.g. "Mathlib/Order/MinLayer.lean". -/
  targetPath         : String
  /-- Target module name, e.g. "Mathlib.Order.MinLayer" (or `…_Upstreamed`). -/
  targetModule       : String
  /-- Whether the target was renamed to `_Upstreamed.lean` due to collision. -/
  collided           : Bool
  /-- Original options (for `noVerifyClean` etc.). -/
  opts               : Options

private def err (s : String) : IO α := throw (IO.userError s)

/-- Step through path components looking for the first occurrence of "Mathlib"
    or "ToMathlib". Returns the search root namespace and the components after it. -/
private def detectSearchRoot (parts : List String) : Option (String × List String) :=
  let rec go (prefixAcc : List String) (rest : List String) : Option (String × List String) :=
    match rest with
    | [] => none
    | seg :: more =>
      if (seg == "Mathlib" || seg == "ToMathlib") && !prefixAcc.isEmpty then
        let ns := ".".intercalate (prefixAcc.reverse ++ [seg])
        some (ns, more)
      else go (seg :: prefixAcc) more
  go [] parts

/-- Convert a search-root namespace (e.g. "Carleson.ToMathlib") to its path
    components. -/
private def searchRootToParts (ns : String) : List String :=
  ns.splitOn "."

/-- Phase 0: resolve every input path, detect the search root, audit working
    trees. Throws on any failure. -/
def resolveInputs (opts : Options) : IO Resolved := do
  -- Absolutize.
  let downstreamAbs ← IO.FS.realPath opts.downstream
  let mathlibAbs    ← IO.FS.realPath opts.mathlib
  let candidateAbs  ← IO.FS.realPath opts.candidate
  -- Sanity: candidate is a .lean file inside downstream.
  unless (← candidateAbs.pathExists) do
    err s!"candidate does not exist: {candidateAbs}"
  unless candidateAbs.toString.endsWith ".lean" do
    err s!"candidate is not a .lean file: {candidateAbs}"
  let some candRelParts := relativizeAbs downstreamAbs candidateAbs
    | err s!"candidate {candidateAbs} is not inside downstream {downstreamAbs}"
  -- Search root: explicit or auto-detected.
  let (searchRoot, candRelToSearchRoot) ←
    match opts.searchRoot with
    | some ns =>
      let nsParts := searchRootToParts ns
      let nsLen := nsParts.length
      if candRelParts.take nsLen ≠ nsParts then
        err s!"--search-root {ns} does not prefix candidate path {candRelParts}"
      else pure (ns, candRelParts.drop nsLen)
    | none =>
      let some (ns, rest) := detectSearchRoot candRelParts
        | err s!"could not auto-detect search root in {candRelParts}; pass --search-root"
      pure (ns, rest)
  -- Project name: first segment of search root.
  let projectName := (searchRootToParts searchRoot).head?
    |>.getD ""
  if projectName.isEmpty then err s!"empty project name from search root {searchRoot}"
  -- Source module.
  let sourceModule := ".".intercalate ((searchRootToParts searchRoot) ++
    candRelToSearchRoot.map (fun p =>
      if p.endsWith ".lean" then (p.dropEnd 5).copy else p))
  -- Target path: --target or mirror.
  let initialTargetPath : String ← match opts.target with
    | some t =>
      if !t.startsWith "Mathlib/" then err s!"--target must start with Mathlib/, got {t}"
      if !t.endsWith ".lean" then err s!"--target must end with .lean, got {t}"
      pure t
    | none =>
      pure ("Mathlib/" ++ "/".intercalate candRelToSearchRoot)
  -- Collision detection.
  let mut targetPath : String := initialTargetPath
  let mut collided : Bool := false
  let candidateTargetAbs := mathlibAbs / targetPath
  if (← candidateTargetAbs.pathExists) then
    -- Append _Upstreamed before .lean.
    let stripped := (targetPath.dropEnd 5).copy
    targetPath := stripped ++ "_Upstreamed.lean"
    collided := true
    let collidedTargetAbs := mathlibAbs / targetPath
    if (← collidedTargetAbs.pathExists) then
      err s!"both {candidateTargetAbs} and {collidedTargetAbs} already exist; aborting"
  -- Derive target module name from path.
  let some targetModule := pathToModule targetPath
    | err s!"failed to derive module name from target path {targetPath}"
  -- Working trees clean (unless --no-verify-clean).
  unless opts.noVerifyClean do
    unless (← Git.isWorkingTreeClean downstreamAbs) do
      err s!"downstream working tree {downstreamAbs} is dirty; commit or stash first (or pass --no-verify-clean)"
    unless (← Git.isWorkingTreeClean mathlibAbs) do
      err s!"mathlib working tree {mathlibAbs} is dirty; commit or stash first (or pass --no-verify-clean)"
  return {
    candidateAbs, downstreamAbs, mathlibAbs,
    candRelToDownstream := candRelParts,
    projectName, searchRoot, candRelToSearchRoot,
    sourceModule, targetPath, targetModule, collided, opts,
  }

/-- Read the `mathlib` dep's `rev` from `<downstream>/lake-manifest.json`. -/
private def pinnedMathlibRev (downstreamAbs : System.FilePath) : IO (Option String) := do
  let manifestPath := downstreamAbs / "lake-manifest.json"
  unless (← manifestPath.pathExists) do return none
  let contents ← IO.FS.readFile manifestPath
  match Json.parse contents with
  | .error e => err s!"failed to parse lake-manifest.json: {e}"
  | .ok j =>
    let pkgs := j.getObjValD "packages"
    let .ok arr := pkgs.getArr?
      | return none
    for pkg in arr do
      match (pkg.getObjValD "name").getStr? with
      | .ok "mathlib" => return (pkg.getObjValD "rev").getStr?.toOption
      | _ => pure ()
    return none

/-- Phase 1: print a warning if the downstream's pinned mathlib rev differs
    from the local checkout's HEAD. -/
def warnCommitMismatch (r : Resolved) : IO Unit := do
  let some pinned ← pinnedMathlibRev r.downstreamAbs
    | IO.println "ℹ no mathlib pin found in lake-manifest.json; skipping commit-mismatch check"
  let head ← Git.getHead r.mathlibAbs
  if pinned == head then
    IO.println s!"✓ mathlib commits aligned ({pinned})"
  else
    IO.println s!"⚠ commit mismatch:"
    IO.println s!"    {r.downstreamAbs} pins mathlib at {pinned}"
    IO.println s!"    {r.mathlibAbs} HEAD is        {head}"
    IO.println s!"  build failures below may reflect API drift between these commits."

/-- Phase 2: refuse if the candidate imports staging-area or project-internal
    modules. -/
def auditImports (r : Resolved) : IO Unit := do
  let contents ← IO.FS.readFile r.candidateAbs
  let imports := extractImports contents
  let stagingNamespaces := [r.projectName ++ ".ToMathlib", r.projectName ++ ".Mathlib"]
  let (staging, project) := classifyImports r.projectName stagingNamespaces imports
  if staging.isEmpty && project.isEmpty then
    IO.println s!"✓ candidate imports look clean ({imports.size} import lines audited)"
    return
  if !staging.isEmpty then
    IO.eprintln "✗ candidate imports sibling staging files:"
    for imp in staging do
      IO.eprintln s!"    line {imp.lineNo}: {imp.module}"
    IO.eprintln "  upstream those first, then retry."
  if !project.isEmpty then
    IO.eprintln "✗ candidate imports downstream-only modules:"
    for imp in project do
      IO.eprintln s!"    line {imp.lineNo}: {imp.module}"
    IO.eprintln "  these have no equivalent in mathlib; this file cannot be upstreamed as-is."
  err "import audit failed"

/-- Phase 4: copy candidate bytes into the mathlib target path. -/
def copyToMathlib (r : Resolved) : IO Unit := do
  let dest := r.mathlibAbs / r.targetPath
  let some destParent := dest.parent | err s!"unexpected: target {dest} has no parent"
  mkdirP destParent
  let bytes ← IO.FS.readBinFile r.candidateAbs
  IO.FS.writeBinFile dest bytes
  IO.println s!"✓ copied {r.candidateAbs} → {dest}"
  if r.collided then
    IO.println s!"  (target already existed; used _Upstreamed suffix)"

/-- Phase 5: build the new file inside mathlib. On failure, remove the copy. -/
def buildMathlib (r : Resolved) : IO Unit := do
  IO.println s!"→ lake exe cache get  (in {r.mathlibAbs})"
  let cacheChild ← IO.Process.spawn {
    cmd := "lake", args := #["exe", "cache", "get"], cwd := r.mathlibAbs
  }
  let cacheCode ← cacheChild.wait
  if cacheCode ≠ 0 then
    IO.println s!"⚠ `lake exe cache get` exited {cacheCode}; continuing anyway (may rebuild from source)"
  IO.println s!"→ lake build {r.targetModule}  (in {r.mathlibAbs})"
  let buildChild ← IO.Process.spawn {
    cmd := "lake", args := #["build", r.targetModule], cwd := r.mathlibAbs
  }
  let buildCode ← buildChild.wait
  if buildCode ≠ 0 then
    -- Roll back the copy so mathlib working tree is clean.
    let dest := r.mathlibAbs / r.targetPath
    try IO.FS.removeFile dest catch _ => pure ()
    err s!"`lake build {r.targetModule}` failed in mathlib (exit {buildCode}); candidate is not ready to upstream. Removed the copy."
  IO.println s!"✓ {r.targetModule} builds inside mathlib"

/-- Phase 6: rewrite the downstream's mathlib dependency to point at the local
    mathlib, then `lake update mathlib`. -/
def redirectDependency (r : Resolved) : IO Unit := do
  IO.println s!"→ rewriting mathlib dep in {r.downstreamAbs}'s lakefile to {r.mathlibAbs}"
  Hopscotch.LakefileProcessor.setPathAny r.downstreamAbs "mathlib" r.mathlibAbs.toString
  IO.println s!"→ lake update mathlib  (in {r.downstreamAbs})"
  let child ← IO.Process.spawn {
    cmd := "lake", args := #["update", "mathlib"], cwd := r.downstreamAbs
  }
  let code ← child.wait
  if code ≠ 0 then
    err s!"`lake update mathlib` failed (exit {code}); see output above"
  IO.println s!"✓ downstream now uses local mathlib"

/-- Phase 7: replace the candidate file with a re-export stub. -/
def writeReexportStub (r : Resolved) : IO Unit := do
  let stub :=
    s!"/-\n" ++
    s!"This file was upstreamed by `upstreamer` to `{r.targetModule}`.\n" ++
    s!"This stub re-exports it so the rest of the project still builds. After the\n" ++
    s!"upstreamed PR is merged into mathlib, replace this stub by removing the file\n" ++
    s!"and the corresponding `import {r.sourceModule}` lines, or by replacing this\n" ++
    s!"with a plain `public import {r.targetModule}` if you want to keep the alias.\n" ++
    s!"-/\n" ++
    s!"module\n\n" ++
    s!"public import {r.targetModule}\n"
  IO.FS.writeFile r.candidateAbs stub
  IO.println s!"✓ replaced {r.candidateAbs} with a re-export stub for {r.targetModule}"

/-- Phase 8: build the downstream. -/
def buildDownstream (r : Resolved) : IO Unit := do
  IO.println s!"→ lake build  (in {r.downstreamAbs})"
  let child ← IO.Process.spawn {
    cmd := "lake", args := #["build"], cwd := r.downstreamAbs
  }
  let code ← child.wait
  if code ≠ 0 then
    err s!"downstream `lake build` failed (exit {code}); see output above. Changes left in place for inspection."
  IO.println s!"✓ downstream builds against local mathlib with the upstreamed file"

/-- Common end-of-run summary printer. Used for both dry-run (no files
    touched) and full-run (8 phases completed) outcomes. The final
    `RESULT\t…` line is tab-separated and machine-parseable, intended for
    batch consumers. -/
def printSummary (r : Resolved) (dryRun : Bool) (elapsedMs : Nat) : IO Unit := do
  IO.println ""
  IO.println "════════════════════════════════════════════════════════"
  if dryRun then
    IO.println "  ✓ dry-run: candidate looks valid; no files touched"
  else
    IO.println "  ✓ candidate built in mathlib AND downstream still builds"
  IO.println "════════════════════════════════════════════════════════"
  IO.println s!"  source:   {r.sourceModule}"
  IO.println s!"  target:   {r.targetModule}"
  if r.collided then
    let verb := if dryRun then "would use" else "used"
    IO.println s!"            (target file already exists; {verb} _Upstreamed suffix)"
  IO.println s!"  duration: {elapsedMs / 1000}s"
  if !dryRun then
    IO.println ""
    IO.println "  to revert these changes:"
    IO.println s!"    cd {r.downstreamAbs} && git checkout . && lake update mathlib"
    IO.println s!"    cd {r.mathlibAbs}    && git checkout . && git clean -fd"
  -- Final tab-separated machine-readable line.
  let status := if dryRun then "dry-run-ok" else "ok"
  IO.println ""
  IO.println s!"RESULT\tstatus={status}\tsource={r.sourceModule}\ttarget={r.targetModule}\tcollision={r.collided}\tduration_ms={elapsedMs}"

/-- Run all phases. When `opts.dryRun` is set, exit after the import audit
    (Phase 2) and report what *would* happen, without touching any files. -/
def run (opts : Options) : IO Unit := do
  let startMs ← IO.monoMsNow
  let r ← resolveInputs opts
  warnCommitMismatch r
  auditImports r
  if opts.dryRun then
    let elapsed := (← IO.monoMsNow) - startMs
    printSummary r (dryRun := true) elapsed
    return
  copyToMathlib r
  buildMathlib r
  redirectDependency r
  writeReexportStub r
  buildDownstream r
  let elapsed := (← IO.monoMsNow) - startMs
  printSummary r (dryRun := false) elapsed

end Upstreamer.Workflow
