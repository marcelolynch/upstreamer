/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
Post-validate state detection, shared by the `commit`, `revert`, and
`build` subcommands. None of them recompute path mappings — they all
read what validate left behind out of `git status`.

Two shapes are recognized — corresponding to validate/stage's two modes:

  Stub mode (default):
    - upstream: 1 untracked `.lean` file under the upstream namespace dir
    - downstream: `lakefile.toml` (or `.lean`), `lake-manifest.json`, and
      exactly 1 modified `.lean` file (the re-export stub)

  Replaced mode (`--replace-imports`):
    - upstream: 1 untracked `.lean` file under the upstream namespace dir
    - downstream: `lakefile.toml` (or `.lean`), `lake-manifest.json`,
      exactly 1 deleted `.lean` file (the candidate), and 0+ modified
      `.lean` files (consumers whose imports were rewritten)
-/
import Upstreamer.Git

namespace Upstreamer.State

/-- Which mode the workspace was staged in. -/
inductive Mode where
  /-- The candidate was overwritten with a re-export stub. -/
  | stub
  /-- The candidate was deleted; consumer imports rewritten. -/
  | replaced
  deriving Repr, BEq

/-- Snapshot extracted from `git status` after a successful `validate`. -/
structure PostValidate where
  /-- Path of the new file in upstream, relative to upstream root. -/
  upstreamTargetRel : String
  /-- Path of the candidate in the downstream, relative to downstream root.
      For `Mode.stub` this is the modified file (now a re-export stub);
      for `Mode.replaced` this is the deleted file. -/
  candidateRel     : String
  /-- True iff the new file ends in `_Upstreamed.lean`. -/
  collided         : Bool
  /-- Workspace shape — `stub` (default validate/stage) vs `replaced`
      (`--replace-imports`). -/
  mode             : Mode

private def err (s : String) : IO α := throw (IO.userError s)

/-- Untracked `.lean` paths under `<upstreamPathAbs>/<upstreamSubdir>/`, relative
    to mathlib root. `upstreamSubdir` is the upstream namespace converted
    to a path (e.g. `"Mathlib"` for the `Mathlib` namespace). -/
def untrackedUpstreamLeanFiles
    (upstreamPathAbs : System.FilePath) (upstreamSubdir : String) : IO (Array String) := do
  let (code, stdout, stderr) ← Git.runGit upstreamPathAbs #["status", "--porcelain", "-uall", upstreamSubdir]
  if code ≠ 0 then
    err s!"git status in {upstreamPathAbs} failed: {stderr.trimAscii.copy}"
  let mut acc : Array String := #[]
  for rawLine in stdout.splitOn "\n" do
    let line := rawLine.trimAsciiEnd.copy
    if line.startsWith "?? " then
      let path := (line.drop 3).copy
      if path.endsWith ".lean" then
        acc := acc.push path
  return acc

/-- Modified tracked files in a repo (worktree-modified, staged, or both),
    relative to the repo root. Excludes deletions and renames. -/
def modifiedTrackedFiles (repoAbs : System.FilePath) : IO (Array String) := do
  let (code, stdout, stderr) ← Git.runGit repoAbs #["status", "--porcelain"]
  if code ≠ 0 then
    err s!"git status in {repoAbs} failed: {stderr.trimAscii.copy}"
  let mut acc : Array String := #[]
  for rawLine in stdout.splitOn "\n" do
    let line := rawLine.trimAsciiEnd.copy
    if line.startsWith " M " || line.startsWith "M  " || line.startsWith "MM " then
      let path := (line.drop 3).copy
      acc := acc.push path
  return acc

/-- Tracked files that have been deleted in the worktree (or staged for
    deletion), relative to the repo root. -/
def deletedTrackedFiles (repoAbs : System.FilePath) : IO (Array String) := do
  let (code, stdout, stderr) ← Git.runGit repoAbs #["status", "--porcelain"]
  if code ≠ 0 then
    err s!"git status in {repoAbs} failed: {stderr.trimAscii.copy}"
  let mut acc : Array String := #[]
  for rawLine in stdout.splitOn "\n" do
    let line := rawLine.trimAsciiEnd.copy
    if line.startsWith " D " || line.startsWith "D  " then
      let path := (line.drop 3).copy
      acc := acc.push path
  return acc

/-- Throws unless the workspace looks like a successful post-validate.
    `upstreamNamespace` (default `"Mathlib"`) is the namespace prefix the
    candidate was upstreamed into; we filter `git status` by its
    path-equivalent. -/
def detect (downstreamAbs upstreamPathAbs : System.FilePath)
    (upstreamNamespace : String := "Mathlib") : IO PostValidate := do
  let upstreamSubdir := upstreamNamespace.replace "." "/"
  let untracked ← untrackedUpstreamLeanFiles upstreamPathAbs upstreamSubdir
  if untracked.size = 0 then
    err s!"no untracked .lean file under upstream's {upstreamSubdir}/. Run `upstreamer <candidate>` first."
  if untracked.size > 1 then
    err s!"expected exactly 1 untracked .lean file under upstream's {upstreamSubdir}/, found {untracked.size}: {untracked}. Clean up first."
  let upstreamTargetRel := untracked[0]!
  let collided := upstreamTargetRel.endsWith "_Upstreamed.lean"
  let modified ← modifiedTrackedFiles downstreamAbs
  let deleted ← deletedTrackedFiles downstreamAbs
  let hasLakefile := modified.contains "lakefile.toml" || modified.contains "lakefile.lean"
  let hasManifest := modified.contains "lake-manifest.json"
  let leanModified := modified.filter (·.endsWith ".lean")
  let leanDeleted := deleted.filter (·.endsWith ".lean")
  unless hasLakefile do
    err "downstream lakefile is not modified — run `upstreamer <candidate>` first to validate."
  unless hasManifest do
    err "downstream lake-manifest.json is not modified — run `upstreamer <candidate>` first to validate."
  -- Replaced mode: exactly 1 deleted .lean (the candidate) + 0+ modified
  -- .lean (consumers). Stub mode: 0 deleted + exactly 1 modified.
  if leanDeleted.size > 1 then
    err s!"expected at most 1 deleted .lean file in downstream, found {leanDeleted.size}: {leanDeleted}. Resolve manually first."
  if leanDeleted.size == 1 then
    return { upstreamTargetRel, candidateRel := leanDeleted[0]!, collided, mode := .replaced }
  -- No deletion ⇒ stub mode.
  if leanModified.size != 1 then
    err s!"expected exactly 1 modified .lean file in downstream (stub mode) or 1 deleted .lean (replaced mode), found {leanModified.size} modified: {leanModified}. Resolve manually first."
  return { upstreamTargetRel, candidateRel := leanModified[0]!, collided, mode := .stub }

end Upstreamer.State
