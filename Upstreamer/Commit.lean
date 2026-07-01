/-
The `commit` phase. After `validate` (or `stage` + `build`) succeeds,
this stages the resulting workspace onto fresh branches in both
repositories, ready for two interrelated PRs:

  - **upstream PR**: adds the new file. The branch's diff is exactly the
    upstreamed file.
  - **downstream PR**: commits whatever shape `validate`/`stage` left the
    workspace in:
      * **stub** (default): the candidate is replaced with a 3-line
        re-export stub of the upstreamed module.
      * **replaced** (when `validate`/`stage --replace-imports` was used):
        the candidate is deleted and every `import <source-module>` line
        across the downstream is rewritten to the upstreamed module.

The downstream branch's lakefile and lake-manifest are reverted to the
original git pin, so its diff contains only the candidate-related
changes. The PR will not build standalone until the upstream PR merges
and the upstream pin is bumped — that's intentional and signalled in the
commit message.

`commit` itself takes no `--replace-imports` flag — it just commits
whatever's there. The mode is decided by `validate`/`stage`.

The commit phase reads the post-validate state out of `git status` rather
than recomputing path mappings, keeping it loosely coupled to validate.
-/
import Upstreamer.Git
import Upstreamer.Util
import Upstreamer.ImportScan
import Upstreamer.ImportRewrite
import Upstreamer.State

namespace Upstreamer.Commit

/-- Inputs for the commit phase. -/
structure Options where
  downstream : String := "."
  upstreamPath : String
  /-- Branch name to create in **both** repositories. Default:
      `upstream/<lowercase-basename>`. -/
  branch     : Option String := none
  /-- Upstream namespace, used to filter post-validate state detection.
      Default `"Mathlib"`. -/
  upstreamNamespace : String := "Mathlib"
  /-- Lakefile dep name in the downstream's `[[require]]` (e.g. `"mathlib"`).
      Used in commit-message and PR-summary text. -/
  upstreamName      : String := "mathlib"
  deriving Repr

private def err (s : String) : IO α := throw (IO.userError s)

/-- Strip a possible `_Upstreamed` suffix from a basename. -/
private def stripUpstreamedSuffix (s : String) : String :=
  if s.endsWith "_Upstreamed" then (s.dropEnd "_Upstreamed".length).copy else s

/-- Strip a possible `_Upstreamed` segment from the end of a module name.
    `"Mathlib.Foo.Bar_Upstreamed"` → `"Mathlib.Foo.Bar"`. -/
private def stripUpstreamedFromModule (mod : String) : String :=
  if mod.endsWith "_Upstreamed" then (mod.dropEnd "_Upstreamed".length).copy else mod

/-- Last path component, with `.lean` stripped. -/
private def basenameNoExt (path : String) : String :=
  let parts := path.splitOn "/"
  let last := parts.getLast!
  if last.endsWith ".lean" then (last.dropEnd 5).copy else last

/-- Lower-case (ASCII only). -/
private def asciiLower (s : String) : String :=
  s.map (fun c => if 'A' ≤ c && c ≤ 'Z' then Char.ofNat (c.toNat + 32) else c)

/-- True iff `branch` already exists as a local ref in `dir`. -/
private def branchExists (dir : System.FilePath) (branch : String) : IO Bool := do
  let (code, _, _) ← Git.runGit dir #["show-ref", "--verify", "--quiet", s!"refs/heads/{branch}"]
  return code == 0

/-- The current ref of `dir`'s HEAD: the branch name if on a branch,
    otherwise the short SHA (detached HEAD). Used for the abandon-instructions
    in the post-commit summary. -/
private def currentRef (dir : System.FilePath) : IO String := do
  let (code, stdout, _) ← Git.runGit dir #["symbolic-ref", "--short", "HEAD"]
  if code == 0 then return stdout.trimAscii.copy
  let (_, sha, _) ← Git.runGit dir #["rev-parse", "--short", "HEAD"]
  return sha.trimAscii.copy

private def runGitOrFail (dir : System.FilePath) (args : Array String) : IO Unit := do
  let (code, _, stderr) ← Git.runGit dir args
  if code ≠ 0 then
    let argsStr := String.intercalate " " args.toList
    err s!"`git {argsStr}` in {dir} failed: {stderr.trimAscii.copy}"

/-- The commit phase entry point. -/
def run (opts : Options) : IO Unit := do
  let downstreamAbs ← IO.FS.realPath opts.downstream
  let upstreamPathAbs    ← IO.FS.realPath opts.upstreamPath
  let st ← State.detect downstreamAbs upstreamPathAbs opts.upstreamNamespace
  let modeDesc :=
    match st.mode with
    | .stub     => "re-export stub"
    | .replaced => "candidate deleted + consumer imports rewritten"
  IO.println "✓ post-validate state recognized:"
  IO.println s!"    upstream new file:       {st.upstreamTargetRel}"
  IO.println s!"    downstream candidate:    {st.candidateRel}"
  IO.println s!"    workspace shape:         {modeDesc}"
  if st.collided then
    IO.println "    (collision — the upstream file is `_Upstreamed`; merge with the existing file by hand before opening the upstream PR)"
  let some targetModule := Util.pathToModule st.upstreamTargetRel
    | err s!"couldn't derive module name from {st.upstreamTargetRel}"
  let canonicalTarget := stripUpstreamedFromModule targetModule
  let sourceModule := Util.pathToModule st.candidateRel |>.getD st.candidateRel
  let basename := stripUpstreamedSuffix (basenameNoExt st.upstreamTargetRel)
  let branch := opts.branch.getD s!"upstream/{asciiLower basename}"
  IO.println s!"    branch name:             {branch}"
  IO.println ""
  if (← branchExists upstreamPathAbs branch) then
    err s!"branch '{branch}' already exists in {upstreamPathAbs}. Pick a different --branch or delete it first."
  if (← branchExists downstreamAbs branch) then
    err s!"branch '{branch}' already exists in {downstreamAbs}. Pick a different --branch or delete it first."
  -- Capture the current refs before we start branching, so we can tell the
  -- user how to come back to them if they want to abandon the new branches.
  let upstreamOrigRef   ← currentRef upstreamPathAbs
  let downstreamOrigRef ← currentRef downstreamAbs
  -- Upstream side: branch + add + commit.
  IO.println s!"→ upstream: creating branch '{branch}' and committing {st.upstreamTargetRel}"
  runGitOrFail upstreamPathAbs #["checkout", "-b", branch]
  runGitOrFail upstreamPathAbs #["add", st.upstreamTargetRel]
  let upstreamMsg :=
    s!"feat: upstream {basename} ({canonicalTarget})\n\n" ++
    s!"Validated locally with the `upstreamer` tool: this file builds inside\n" ++
    s!"`{opts.upstreamNamespace}` and the originating downstream project still type-checks against it.\n"
  runGitOrFail upstreamPathAbs #["commit", "-m", upstreamMsg]
  IO.println s!"✓ upstream branch '{branch}' has 1 commit"
  -- Downstream side: revert lakefile + manifest, branch, then commit
  -- whatever shape the workspace is in (stub or replaced — set by validate
  -- or stage, optionally with --replace-imports).
  IO.println s!"→ downstream: reverting lakefile + manifest, creating branch '{branch}'"
  runGitOrFail downstreamAbs #["checkout", "--", "lakefile.toml", "lake-manifest.json"]
  -- Try lakefile.lean too (no-op if absent or unchanged).
  let _ ← Git.runGit downstreamAbs #["checkout", "--", "lakefile.lean"]
  runGitOrFail downstreamAbs #["checkout", "-b", branch]
  let downstreamMsg ←
    match st.mode with
    | .replaced => do
      -- Stage the deletion of the candidate + every rewritten consumer
      -- (and possibly the project-root .lean if it imported the candidate).
      let modified ← State.modifiedTrackedFiles downstreamAbs
      let consumers := (modified.filter (·.endsWith ".lean")).filter (· ≠ st.candidateRel)
      runGitOrFail downstreamAbs (#["add", "--", st.candidateRel] ++ consumers)
      let consumerLine :=
        if consumers.isEmpty then "  (no consumer files needed rewriting)"
        else s!"- Rewrites every `import {sourceModule}` to `import {canonicalTarget}`\n  ({consumers.size} consumer file(s) updated)."
      pure (
        s!"chore: upstream {basename} (now {canonicalTarget})\n\n" ++
        s!"- Deletes `{st.candidateRel}`.\n" ++
        consumerLine ++ "\n\n" ++
        s!"Depends on the corresponding upstream PR. After it merges, bump the `{opts.upstreamName}` pin\n" ++
        s!"in `lake-manifest.json` to a commit including `{canonicalTarget}` and merge this.\n")
    | .stub => do
      runGitOrFail downstreamAbs #["add", st.candidateRel]
      pure (
        s!"chore({st.candidateRel}): replace with re-export stub for {targetModule}\n\n" ++
        s!"Depends on the corresponding upstream PR. After it merges, bump the `{opts.upstreamName}` pin\n" ++
        s!"in `lake-manifest.json` to a commit including `{canonicalTarget}` and merge this.\n" ++
        s!"The stub then transitively re-exports from the upstreamed module so every\n" ++
        s!"existing `import {sourceModule}` line keeps working unchanged.\n")
  runGitOrFail downstreamAbs #["commit", "-m", downstreamMsg]
  IO.println s!"✓ downstream branch '{branch}' has 1 commit"
  -- Final summary.
  IO.println ""
  IO.println "════════════════════════════════════════════════════════"
  IO.println "  ✓ branches staged for two interrelated PRs"
  IO.println "════════════════════════════════════════════════════════"
  IO.println s!"  upstream   branch:  {branch}    in {upstreamPathAbs}"
  IO.println s!"  downstream branch:  {branch}    in {downstreamAbs}"
  IO.println ""
  IO.println "  next steps:"
  IO.println s!"    1. cd {upstreamPathAbs} && git push -u origin {branch}"
  IO.println       "       open the upstream PR; copy the commit body into the PR description."
  IO.println s!"    2. cd {downstreamAbs} && git push -u origin {branch}"
  IO.println s!"       open the downstream PR; reference the upstream PR. CI will fail"
  IO.println s!"       until the upstream PR merges and the `{opts.upstreamName}` pin is bumped here."
  IO.println ""
  IO.println "  to abandon these branches and return to the previous state:"
  IO.println s!"    cd {upstreamPathAbs}    && git checkout {upstreamOrigRef}   && git branch -D {branch}"
  IO.println s!"    cd {downstreamAbs} && git checkout {downstreamOrigRef} && git branch -D {branch}"
  if st.collided then
    IO.println ""
    IO.println "  ⚠ collision: the upstream branch contains a `_Upstreamed.lean` file."
    IO.println "    Before opening the upstream PR, manually merge it with the existing"
    IO.println "    file at the un-suffixed path, and amend the commit (`git commit --amend`)."
  IO.println ""
  let modeStr := match st.mode with | .stub => "stub" | .replaced => "replaced"
  IO.println s!"RESULT\tstatus=commit-ok\tbranch={branch}\tupstream_file={st.upstreamTargetRel}\tdownstream_file={st.candidateRel}\tcollision={st.collided}\tmode={modeStr}"

end Upstreamer.Commit
