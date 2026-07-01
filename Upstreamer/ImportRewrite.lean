/-
Helpers for rewriting `import <module>` lines across a project tree.
Used by both `--replace-imports` paths: the staging-time variant
(`Workflow.replaceImports`) and the post-validate variant
(`Commit.run`).
-/
import Upstreamer.ImportScan
import Upstreamer.Util

namespace Upstreamer.ImportRewrite

/-- Recursively collect every `.lean` file under `root`, skipping `.git`,
    `.lake`, `build`, and other dot-prefixed entries. -/
partial def collectLeanFiles (root : System.FilePath) : IO (Array System.FilePath) := do
  unless (← root.pathExists) do return #[]
  if (← root.isDir) then
    let mut acc : Array System.FilePath := #[]
    for entry in (← root.readDir) do
      let name := entry.fileName
      if name.startsWith "." then continue
      if name == "build" then continue
      acc := acc.append (← collectLeanFiles entry.path)
    return acc
  else
    if root.toString.endsWith ".lean" then return #[root]
    return #[]

/-- Rewrite a single line: if it's an `import <oldMod>` directive (with
    optional `public`/`private`/`meta` modifier), replace the module name
    with `newMod` while preserving everything else (whitespace, modifier,
    trailing comments). Lines that aren't an exact import of `oldMod` are
    returned unchanged. -/
def rewriteImportLine (line : String) (oldMod newMod : String) : String :=
  match ImportScan.parseImport? line 0 with
  | none => line
  | some imp =>
    if imp.module ≠ oldMod then line
    -- The module name token appears exactly once on an import line, after
    -- `import `. `String.replace` is safe here.
    else line.replace oldMod newMod

def rewriteImportsInContent (content oldMod newMod : String) : String :=
  let lines := content.splitOn "\n"
  let newLines := lines.map (rewriteImportLine · oldMod newMod)
  "\n".intercalate newLines

/-- Walk every `.lean` file under `<downstream>/<projectDir>/` plus
    `<downstream>/<projectDir>.lean`, and rewrite every `import oldMod`
    line to `import newMod`. Skips `skipFile` (the candidate, which
    is going to be deleted). Returns the list of relative paths that were
    actually modified. -/
def rewriteImportsInProject
    (downstreamAbs : System.FilePath) (projectDir : String)
    (oldMod newMod : String) (skipFile : System.FilePath)
    : IO (Array String) := do
  let projectRoot := downstreamAbs / projectDir
  let projectFile := downstreamAbs / s!"{projectDir}.lean"
  let mut allFiles ← collectLeanFiles projectRoot
  if (← projectFile.pathExists) then
    allFiles := allFiles.push projectFile
  let skipStr := skipFile.toString
  let mut mutated : Array String := #[]
  for f in allFiles do
    if f.toString == skipStr then continue
    let content ← IO.FS.readFile f
    let newContent := rewriteImportsInContent content oldMod newMod
    if newContent != content then
      IO.FS.writeFile f newContent
      if let some rel := Util.relativizeAbs downstreamAbs f then
        mutated := mutated.push ("/".intercalate rel)
  return mutated

end Upstreamer.ImportRewrite
