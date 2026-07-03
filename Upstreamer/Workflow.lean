/-
The end-to-end upstreaming workflow. Each phase from the design plan is its
own def; `run` chains them and surfaces failure modes with clear messages.
-/
import Hopscotch.LakefileProcessor
import Upstreamer.Git
import Upstreamer.ImportScan
import Upstreamer.ImportRewrite
import Upstreamer.Util

open Upstreamer.ImportScan Upstreamer.Util

namespace Upstreamer.Workflow

/-- Inputs to a single upstreaming run. Built by `Upstreamer.CLI` from the
    parsed command line. -/
structure Options where
  /-- Path to the candidate `.lean` file (absolute or relative to CWD). -/
  candidate     : String
  /-- Path to the downstream project root. Default: ".". -/
  downstream    : String := "."
  /-- Path to the local upstream clone (e.g. a local mathlib4 clone). Required. -/
  upstreamPath  : String
  /-- Lakefile dep name in the downstream's `[[require]]` block (e.g. `"mathlib"`). -/
  upstreamName  : String
  /-- Upstream namespace prefix (e.g. `"Mathlib"`). -/
  upstreamNamespace : String
  /-- Optional override of the destination path inside the upstream
      (e.g. `"Mathlib/Order/MinLayer.lean"`). -/
  target        : Option String := none
  /-- Optional override of the staging-area namespace (e.g.
      `"Carleson.ToMathlib"`). When omitted, auto-detection uses
      `searchRootSegments`. -/
  searchRoot    : Option String := none
  /-- Path-component names that mark the staging-area boundary during
      `--search-root` auto-detection. Coming from the active preset
      (`["Mathlib", "ToMathlib"]` for `mathlib`); empty means no
      auto-detection. -/
  searchRootSegments : List String := []
  /-- Skip the dirty-tree refusal (escape hatch for testing). -/
  noVerifyClean    : Bool := false
  /-- Stream `lake` build output live; otherwise captured and only shown on failure. -/
  verbose          : Bool := false
  /-- If true, instead of writing a re-export stub, delete the candidate
      and rewrite every `import <source-module>` line in the downstream to
      the upstreamed target module. -/
  replaceImports   : Bool := false
  deriving Repr

/-- The fully-resolved configuration after Phase 0. -/
structure Resolved where
  /-- Absolute path to the candidate. -/
  candidateAbs       : System.FilePath
  /-- Absolute path to the downstream root. -/
  downstreamAbs      : System.FilePath
  /-- Absolute path to the local mathlib clone. -/
  upstreamPathAbs         : System.FilePath
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
  /-- Resolved upstream namespace (e.g. "Mathlib"). -/
  upstreamNamespace  : String
  /-- Resolved upstream lakefile dep name (e.g. "mathlib"). -/
  upstreamName       : String
  /-- Original options (for `noVerifyClean` etc.). -/
  opts               : Options

private def err (s : String) : IO α := throw (IO.userError s)

/-- Step through path components looking for the first occurrence of any
    segment in `segments` (e.g. `["Mathlib", "ToMathlib"]` for the `mathlib`
    preset). Returns the search-root namespace and the components after it.
    Returns `none` if no segment matches or `segments` is empty. -/
private def detectSearchRoot (segments : List String)
    (parts : List String) : Option (String × List String) :=
  let rec go (prefixAcc : List String) (rest : List String) : Option (String × List String) :=
    match rest with
    | [] => none
    | seg :: more =>
      if segments.contains seg && !prefixAcc.isEmpty then
        let ns := ".".intercalate (prefixAcc.reverse ++ [seg])
        some (ns, more)
      else go (seg :: prefixAcc) more
  go [] parts

/-- Convert a search-root namespace (e.g. "Carleson.ToMathlib") to its path
    components. -/
private def searchRootToParts (ns : String) : List String :=
  ns.splitOn "."

/-- Phase 0: resolve every input path, detect the search root, compute the
    target path (with `_Upstreamed` collision suffix if needed), audit
    working trees. Throws on any failure. -/
def resolveInputs (opts : Options) : IO Resolved := do
  -- Absolutize. The candidate may be a file path or a dotted module name.
  let downstreamAbs ← IO.FS.realPath opts.downstream
  let upstreamPathAbs    ← IO.FS.realPath opts.upstreamPath
  let candidateAbs  ← Util.resolveCandidateArg downstreamAbs opts.candidate
  -- Sanity: candidate is a .lean file inside downstream.
  unless (← candidateAbs.pathExists) do
    err s!"candidate does not exist: {candidateAbs}"
  unless candidateAbs.toString.endsWith ".lean" do
    err s!"candidate is not a .lean file: {candidateAbs}"
  let some candRelParts := relativizeAbs downstreamAbs candidateAbs
    | err s!"candidate {candidateAbs} is not inside downstream {downstreamAbs}"
  -- Search root: explicit or auto-detected via the configured segments.
  let (searchRoot, candRelToSearchRoot) ←
    match opts.searchRoot with
    | some ns =>
      let nsParts := searchRootToParts ns
      let nsLen := nsParts.length
      if candRelParts.take nsLen ≠ nsParts then
        err s!"--search-root {ns} does not prefix candidate path {candRelParts}"
      else pure (ns, candRelParts.drop nsLen)
    | none =>
      if opts.searchRootSegments.isEmpty then
        err s!"could not auto-detect search root in {candRelParts}: no segments configured. Pass --search-root or use --preset mathlib."
      let some (ns, rest) := detectSearchRoot opts.searchRootSegments candRelParts
        | err s!"could not auto-detect search root in {candRelParts}: no path component matches {opts.searchRootSegments}. Pass --search-root."
      pure (ns, rest)
  -- Project name: first segment of search root.
  let projectName := (searchRootToParts searchRoot).head?
    |>.getD ""
  if projectName.isEmpty then err s!"empty project name from search root {searchRoot}"
  -- Source module.
  let sourceModule := ".".intercalate ((searchRootToParts searchRoot) ++
    candRelToSearchRoot.map (fun p =>
      if p.endsWith ".lean" then (p.dropEnd 5).copy else p))
  -- Upstream namespace (e.g. "Mathlib") and its path equivalent.
  let upstreamNs := opts.upstreamNamespace
  let upstreamSubdir := upstreamNs.replace "." "/"
  -- Target: --target accepts either a `.lean` path (`Mathlib/Order/Foo.lean`)
  -- or a dotted module name (`Mathlib.Order.Foo`); fallback is to mirror
  -- under the upstream namespace.
  let initialTargetPath : String ← match opts.target with
    | some t =>
      let looksLikePath := t.endsWith ".lean" || t.contains '/' || t.contains '\\'
      let asPath := if looksLikePath then t else moduleToPath t
      if !asPath.startsWith (upstreamSubdir ++ "/") then
        err s!"--target must start with {upstreamSubdir} (got {t})"
      if !asPath.endsWith ".lean" then err s!"--target must end with .lean, got {t}"
      pure asPath
    | none =>
      pure (upstreamSubdir ++ "/" ++ "/".intercalate candRelToSearchRoot)
  -- Collision detection.
  let mut targetPath : String := initialTargetPath
  let mut collided : Bool := false
  let candidateTargetAbs := upstreamPathAbs / targetPath
  if (← candidateTargetAbs.pathExists) then
    -- Append _Upstreamed before .lean.
    let stripped := (targetPath.dropEnd 5).copy
    targetPath := stripped ++ "_Upstreamed.lean"
    collided := true
    let collidedTargetAbs := upstreamPathAbs / targetPath
    if (← collidedTargetAbs.pathExists) then
      err s!"both {candidateTargetAbs} and {collidedTargetAbs} already exist; aborting"
  -- Derive target module name from path.
  let some targetModule := pathToModule targetPath
    | err s!"failed to derive module name from target path {targetPath}"
  -- Working trees clean (unless --no-verify-clean).
  unless opts.noVerifyClean do
    unless (← Git.isWorkingTreeClean downstreamAbs) do
      err s!"downstream working tree {downstreamAbs} is dirty; commit or stash first (or pass --no-verify-clean)"
    unless (← Git.isWorkingTreeClean upstreamPathAbs) do
      err s!"upstream working tree {upstreamPathAbs} is dirty; commit or stash first (or pass --no-verify-clean)"
  return {
    candidateAbs, downstreamAbs, upstreamPathAbs,
    candRelToDownstream := candRelParts,
    projectName, searchRoot, candRelToSearchRoot,
    sourceModule, targetPath, targetModule, collided,
    upstreamNamespace := upstreamNs,
    upstreamName := opts.upstreamName,
    opts,
  }

/-- Phase 1: refuse if the candidate imports staging-area or project-internal
    modules. -/
def auditImports (r : Resolved) : IO Unit := do
  let contents ← IO.FS.readFile r.candidateAbs
  let imports := extractImports contents
  let stagingNamespaces := [r.searchRoot]
  let allowed := r.upstreamNamespace :: defaultAllowedPrefixes
  let (staging, project) := classifyImports r.projectName stagingNamespaces allowed imports
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
    IO.eprintln s!"  these have no equivalent in `{r.upstreamName}`; this file cannot be upstreamed as-is."
  err "import audit failed"

/-- Phase 2: copy candidate bytes into the upstream target path. -/
def copyToMathlib (r : Resolved) : IO Unit := do
  let dest := r.upstreamPathAbs / r.targetPath
  let some destParent := dest.parent | err s!"unexpected: target {dest} has no parent"
  mkdirP destParent
  let bytes ← IO.FS.readBinFile r.candidateAbs
  IO.FS.writeBinFile dest bytes
  IO.println s!"✓ copied {r.candidateAbs} → {dest}"
  if r.collided then
    IO.println s!"  (target already existed; used _Upstreamed suffix)"

/-- Phase 3: build the new file inside the upstream. On failure, remove the copy.
    `lake exe cache get` is `mathlib`-specific — we run it best-effort and
    ignore failures, so non-mathlib upstreams just skip the cache step naturally. -/
def buildUpstream (r : Resolved) : IO Unit := do
  IO.println s!"→ lake exe cache get  (in {r.upstreamPathAbs})"
  let cacheCode ← runLake r.opts.verbose r.upstreamPathAbs #["exe", "cache", "get"]
  if cacheCode ≠ 0 then
    IO.println s!"⚠ `lake exe cache get` exited {cacheCode}; continuing anyway (no cache, or non-mathlib upstream)"
  IO.println s!"→ lake build {r.targetModule}  (in {r.upstreamPathAbs})"
  let buildCode ← runLake r.opts.verbose r.upstreamPathAbs #["build", r.targetModule]
  if buildCode ≠ 0 then
    -- Roll back the copy so the upstream working tree is clean.
    let dest := r.upstreamPathAbs / r.targetPath
    try IO.FS.removeFile dest catch _ => pure ()
    err s!"`lake build {r.targetModule}` failed in upstream (exit {buildCode}); candidate is not ready to upstream. Removed the copy."
  IO.println s!"✓ {r.targetModule} builds inside upstream"

/-- Phase 4: rewrite the downstream's `[[require]] name = <upstreamName>` to
    point at the local upstream path, then `lake update <upstreamName>`. -/
def redirectDependency (r : Resolved) : IO Unit := do
  IO.println s!"→ rewriting `{r.upstreamName}` dep in {r.downstreamAbs}'s lakefile to {r.upstreamPathAbs}"
  Hopscotch.LakefileProcessor.setPathAny r.downstreamAbs r.upstreamName r.upstreamPathAbs.toString
  IO.println s!"→ lake update {r.upstreamName}  (in {r.downstreamAbs})"
  let code ← runLake r.opts.verbose r.downstreamAbs #["update", r.upstreamName]
  if code ≠ 0 then
    err s!"`lake update {r.upstreamName}` failed (exit {code}); see output above"
  IO.println s!"✓ downstream now uses local upstream"

/-- Phase 5: replace the candidate file with a re-export stub. -/
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

/-- Phase 5 alternative (`--replace-imports`): instead of writing a re-export
    stub, delete the candidate and rewrite every `import <source-module>`
    line in the downstream to point at the upstreamed target module. The
    canonical target strips any `_Upstreamed` collision suffix — the user
    is committing to merge-by-hand if a collision was detected. -/
def replaceImports (r : Resolved) : IO Unit := do
  let canonicalTarget :=
    if r.targetModule.endsWith "_Upstreamed" then
      (r.targetModule.dropEnd "_Upstreamed".length).copy
    else r.targetModule
  let projectDir := r.projectName
  IO.println s!"→ rewriting `import {r.sourceModule}` → `import {canonicalTarget}` across {projectDir}/"
  let mutated ← ImportRewrite.rewriteImportsInProject
    r.downstreamAbs projectDir r.sourceModule canonicalTarget r.candidateAbs
  if mutated.isEmpty then
    IO.println s!"  (no consumers found — deleting the candidate only)"
  else
    IO.println s!"  rewrote {mutated.size} consumer file(s):"
    for m in mutated do
      IO.println s!"    {m}"
  IO.FS.removeFile r.candidateAbs
  IO.println s!"✓ deleted {r.candidateAbs}"

/-- Phase 6: build the downstream. -/
def buildDownstream (r : Resolved) : IO Unit := do
  IO.println s!"→ lake build  (in {r.downstreamAbs})"
  let code ← runLake r.opts.verbose r.downstreamAbs #["build"]
  if code ≠ 0 then
    err s!"downstream `lake build` failed (exit {code}); see output above. Changes left in place for inspection."
  IO.println s!"✓ downstream builds against local upstream with the upstreamed file"

/-- End-of-run summary printer for the full eight-phase run. The final
    `RESULT\t…` line is tab-separated and machine-parseable. -/
def printSummary (r : Resolved) (elapsedMs : Nat) : IO Unit := do
  IO.println ""
  IO.println "════════════════════════════════════════════════════════"
  IO.println "  ✓ candidate built in upstream AND downstream still builds"
  IO.println "════════════════════════════════════════════════════════"
  IO.println s!"  source:   {r.sourceModule}"
  IO.println s!"  target:   {r.targetModule}"
  if r.collided then
    IO.println s!"            (target file already existed; used _Upstreamed suffix —"
    IO.println s!"             merge by hand before opening a real PR)"
  IO.println s!"  duration: {elapsedMs / 1000}s"
  IO.println ""
  IO.println "  next steps:"
  IO.println       "    `upstreamer commit`             — stage two PR-ready branches"
  IO.println       "    `upstreamer revert`             — abandon"
  IO.println ""
  IO.println s!"RESULT\tstatus=ok\tsource={r.sourceModule}\ttarget={r.targetModule}\tcollision={r.collided}\tduration_ms={elapsedMs}"

/-- Run all phases of the validate flow. -/
def run (opts : Options) : IO Unit := do
  let startMs ← IO.monoMsNow
  let r ← resolveInputs opts
  auditImports r
  copyToMathlib r
  buildUpstream r
  redirectDependency r
  if opts.replaceImports then replaceImports r else writeReexportStub r
  buildDownstream r
  let elapsed := (← IO.monoMsNow) - startMs
  printSummary r elapsed

end Upstreamer.Workflow
