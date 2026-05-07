/-
Tiny shell-out wrappers for git, used to enforce the dirty-tree refusal and
read commit SHAs.
-/

namespace Upstreamer.Git

/-- Run `git <args>` with `cwd = dir`. Returns (exitCode, stdout, stderr). -/
def runGit (dir : System.FilePath) (args : Array String) : IO (UInt32 × String × String) := do
  let out ← IO.Process.output { cmd := "git", args := args, cwd := dir }
  return (out.exitCode, out.stdout, out.stderr)

/-- True iff `git status --porcelain` in `dir` produces empty output. -/
def isWorkingTreeClean (dir : System.FilePath) : IO Bool := do
  let (code, stdout, stderr) ← runGit dir #["status", "--porcelain"]
  if code ≠ 0 then
    throw <| IO.userError s!"git status --porcelain failed in {dir}: {stderr.trimAscii.copy}"
  return stdout.trimAscii.isEmpty

/-- Get HEAD SHA at `dir`. -/
def getHead (dir : System.FilePath) : IO String := do
  let (code, stdout, stderr) ← runGit dir #["rev-parse", "HEAD"]
  if code ≠ 0 then
    throw <| IO.userError s!"git rev-parse HEAD failed in {dir}: {stderr.trimAscii.copy}"
  return stdout.trimAscii.copy

end Upstreamer.Git
