/-
Small path / string / file helpers used across upstreamer.
-/

namespace Upstreamer.Util

/-- Convert a relative `.lean` path to its dotted module name.
    e.g. `Mathlib/Order/MinLayer.lean` → `"Mathlib.Order.MinLayer"`. -/
def pathToModule (relPath : String) : Option String :=
  let suffix := ".lean"
  if !relPath.endsWith suffix then none
  else
    let stripped := (relPath.dropEnd suffix.length).copy
    let dotted := stripped.replace "/" "." |>.replace "\\" "."
    if dotted.isEmpty then none else some dotted

/-- Convert a dotted module name to a relative `.lean` path.
    e.g. `"Mathlib.Order.MinLayer"` → `Mathlib/Order/MinLayer.lean`. -/
def moduleToPath (mod : String) : String :=
  mod.replace "." "/" ++ ".lean"

/-- Split a string into path components on `/` (and `\` on Windows). Drops empty components. -/
def splitPath (s : String) : List String :=
  s.splitOn "/" |>.flatMap (·.splitOn "\\") |>.filter (!·.isEmpty)

/-- Compute `full` relative to `base`, as a list of path components. Returns
    `none` if `full` is not a descendant of `base`. Both must be absolute. -/
def relativizeAbs (base full : System.FilePath) : Option (List String) :=
  let baseStr := base.toString
  let fullStr := full.toString
  let baseStr := if baseStr.endsWith "/" then (baseStr.dropEnd 1).copy else baseStr
  if baseStr == fullStr then some []
  else
    let prefixWithSep := baseStr ++ "/"
    if !fullStr.startsWith prefixWithSep then none
    else some (splitPath (fullStr.drop prefixWithSep.length).copy)

/-- Read the project name from `<projectDir>/lakefile.toml` (top-level `name = "..."`)
    or `<projectDir>/lakefile.lean` (`package "..."` or `package …`). -/
def readProjectName (projectDir : System.FilePath) : IO (Option String) := do
  let lakefileToml := projectDir / "lakefile.toml"
  let lakefileLean := projectDir / "lakefile.lean"
  if (← lakefileToml.pathExists) then
    let contents ← IO.FS.readFile lakefileToml
    let mut inSection := false
    for rawLine in contents.splitOn "\n" do
      let trimmed := rawLine.trimAsciiStart
      if trimmed.startsWith "[" then
        inSection := true
      else if !inSection && trimmed.startsWith "name = \"" then
        let rest := trimmed.drop "name = \"".length
        return some (rest.takeWhile (· ≠ '"')).copy
    return none
  else if (← lakefileLean.pathExists) then
    let contents ← IO.FS.readFile lakefileLean
    for rawLine in contents.splitOn "\n" do
      let trimmed := rawLine.trimAsciiStart
      if trimmed.startsWith "package " then
        let rest := (trimmed.drop "package ".length).trimAscii
        if rest.startsWith "\"" then
          return some ((rest.drop 1).takeWhile (· ≠ '"')).copy
        else
          let id := rest.takeWhile (fun c => c.isAlphanum || c == '_')
          if !id.isEmpty then return some id.copy
    return none
  else return none

/-- Recursive `mkdir -p`. -/
def mkdirP (dir : System.FilePath) : IO Unit :=
  IO.FS.createDirAll dir

end Upstreamer.Util
