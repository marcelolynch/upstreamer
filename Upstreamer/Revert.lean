/-
The `revert` phase: undoes everything `validate` did, returning both
repositories to their pre-validate state. Operates entirely on what's
visible in `git status` — the user doesn't have to remember the candidate
path.

  - mathlib-local: deletes the untracked `.lean` file we copied in, and any
    parent directories that became empty.
  - downstream: `git checkout` restores `lakefile.toml`, `lake-manifest.json`,
    and the stub-overwritten candidate to their committed contents.

No `lake update` is needed afterwards: Lake's path-dependency support
reads the redirected upstream directly without replacing the original
`.lake/packages/<upstream>` git clone, so once the lakefile and manifest
are restored, Lake's state is back in sync with the manifest's pinned rev.
-/
import Upstreamer.Git
import Upstreamer.State

namespace Upstreamer.Revert

structure Options where
  downstream : String := "."
  upstreamPath : String
  /-- Upstream namespace, for state-detection filtering. Default `"Mathlib"`. -/
  upstreamNamespace : String := "Mathlib"
  deriving Repr

private def err (s : String) : IO α := throw (IO.userError s)

/-- Walk up from `start.parent`, removing each empty directory until we
    hit a non-empty directory or `boundary`. Bounded to 50 iterations as a
    safety net. -/
private def cleanupEmptyParents (start : System.FilePath) (boundary : System.FilePath) : IO Unit := do
  let mut cur := start
  for _ in [0:50] do
    let some parent := cur.parent | return
    if parent.toString == boundary.toString then return
    let entries ← try parent.readDir catch _ => pure #[]
    if entries.size > 0 then return
    try IO.FS.removeDir parent catch _ => return
    cur := parent

private def runGitOrFail (dir : System.FilePath) (args : Array String) : IO Unit := do
  let (code, _, stderr) ← Git.runGit dir args
  if code ≠ 0 then
    let argsStr := String.intercalate " " args.toList
    err s!"`git {argsStr}` in {dir} failed: {stderr.trimAscii.copy}"

def run (opts : Options) : IO Unit := do
  let downstreamAbs ← IO.FS.realPath opts.downstream
  let upstreamPathAbs    ← IO.FS.realPath opts.upstreamPath
  let st ← State.detect downstreamAbs upstreamPathAbs opts.upstreamNamespace
  let modeLabel := match st.mode with | .stub => "stub" | .replaced => "replaced (consumers rewritten)"
  IO.println "✓ post-validate state recognized:"
  IO.println s!"    upstream new file:       {st.upstreamTargetRel}"
  IO.println s!"    downstream candidate:    {st.candidateRel}"
  IO.println s!"    mode:                    {modeLabel}"
  IO.println ""
  -- Upstream: remove untracked file (and any parent directories we created).
  let upstreamFile := upstreamPathAbs / st.upstreamTargetRel
  IO.println s!"→ upstream: removing {st.upstreamTargetRel}"
  IO.FS.removeFile upstreamFile
  cleanupEmptyParents upstreamFile upstreamPathAbs
  -- Downstream: collect every candidate-related file and restore them
  -- targeted (so unrelated dirty files in the worktree are left alone).
  let modified ← State.modifiedTrackedFiles downstreamAbs
  let consumers := (modified.filter (·.endsWith ".lean")).filter (· ≠ st.candidateRel)
  let consumerCountStr :=
    if consumers.isEmpty then "" else s!", {consumers.size} rewritten consumer(s)"
  IO.println s!"→ downstream: restoring lakefile.toml, lake-manifest.json, candidate{consumerCountStr}"
  runGitOrFail downstreamAbs
    (#["checkout", "--", "lakefile.toml", "lake-manifest.json", st.candidateRel] ++ consumers)
  -- Try lakefile.lean too in case the downstream uses that variant.
  let _ ← Git.runGit downstreamAbs #["checkout", "--", "lakefile.lean"]
  IO.println ""
  IO.println "✓ workspace reverted to pre-validate state"
  IO.println ""
  IO.println s!"RESULT\tstatus=revert-ok\tupstream_file={st.upstreamTargetRel}\tdownstream_file={st.candidateRel}\tmode={modeLabel}"

end Upstreamer.Revert
