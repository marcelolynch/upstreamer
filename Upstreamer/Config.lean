/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
A `.upstreamer` config file in the downstream root that supplies defaults
for the upstream-side parameters, sparing the user from retyping them on
every invocation. CLI flags always win.

Discovery is git-style: walk upward from CWD until a `.upstreamer` is
found; the directory containing it becomes the implicit `--downstream`.
If the user passes `--downstream` explicitly, no walk happens — only
that directory is checked.

Format: `key = value` lines; `#` and `;` start comments; blank lines OK;
quoted values supported; unknown keys are silently ignored (forward compat).
Relative paths are resolved against the directory containing the file —
so a config can reasonably say `upstream-path = ../mathlib-local`.

Example for a Mathlib downstream:

  ```
  preset             = mathlib
  upstream-path      = ../mathlib-local
  ```

Example for an arbitrary upstream library:

  ```
  upstream-path      = ../my-upstream
  upstream-name      = my-upstream         # the lakefile [[require]] name
  upstream-namespace = MyUpstream          # the namespace prefix
  search-root        = MyProject.Staging   # where staging files live
  ```
-/

namespace Upstreamer.Config

/-- The parsed config. All fields are optional. -/
structure T where
  /-- Preset name (e.g. `"mathlib"`). The preset's defaults are then
      overridden by the explicit fields below. -/
  preset             : Option String := none
  /-- Filesystem path to the local upstream clone. -/
  upstreamPath       : Option String := none
  /-- Lakefile dep name (e.g. `"mathlib"`). -/
  upstreamName       : Option String := none
  /-- Upstream namespace prefix (e.g. `"Mathlib"`). -/
  upstreamNamespace  : Option String := none
  /-- Staging-area namespace (e.g. `"Carleson.ToMathlib"`). -/
  searchRoot         : Option String := none
  deriving Repr

/-- Parse a single line as `key = value`. Returns `none` for blank lines,
    comments, and malformed lines. -/
private def parseLine (line : String) : Option (String × String) :=
  let trimmed := line.trimAscii.copy
  if trimmed.isEmpty then none
  else if trimmed.startsWith "#" || trimmed.startsWith ";" then none
  else
    match trimmed.splitOn "=" with
    | [] => none
    | [_] => none
    | keyPart :: rest =>
      let key := keyPart.trimAscii.copy
      let valRaw := ("=".intercalate rest).trimAscii.copy
      let val :=
        if valRaw.length ≥ 2 && valRaw.front == '"' && valRaw.endsWith "\"" then
          ((valRaw.drop 1).dropEnd 1).copy
        else valRaw
      some (key, val)

/-- Parse the full file contents. Unknown keys are silently ignored. -/
def parse (content : String) : T := Id.run do
  let mut cfg : T := {}
  for rawLine in content.splitOn "\n" do
    if let some (key, val) := parseLine rawLine then
      match key with
      | "preset"             => cfg := { cfg with preset             := some val }
      | "upstream-path"      => cfg := { cfg with upstreamPath       := some val }
      | "upstream-name"      => cfg := { cfg with upstreamName       := some val }
      | "upstream-namespace" => cfg := { cfg with upstreamNamespace  := some val }
      | "search-root"        => cfg := { cfg with searchRoot         := some val }
      | _                    => pure ()
  return cfg

private def loadFile (path : System.FilePath) : IO T := do
  let content ← IO.FS.readFile path
  return parse content

/-- Resolve relative paths in the config against `configDir`. Absolute paths
    pass through; namespace fields are unchanged. -/
private def resolveRelativePaths (configDir : System.FilePath) (cfg : T) : T :=
  let resolveOne (m : String) : String :=
    if (System.FilePath.mk m).isAbsolute then m
    else (configDir / (System.FilePath.mk m)).toString
  { cfg with upstreamPath := cfg.upstreamPath.map resolveOne }

/-- Walk upward from `cur` looking for a `.upstreamer` file. Returns the
    directory containing it and the parsed config. -/
private partial def walkUp (cur : System.FilePath) : IO (Option (System.FilePath × T)) := do
  let candidate := cur / ".upstreamer"
  if (← candidate.pathExists) then
    let cfg ← loadFile candidate
    return some (cur, resolveRelativePaths cur cfg)
  match cur.parent with
  | none => return none
  | some parent =>
    if parent.toString == cur.toString then return none
    walkUp parent

/-- Resolve `--downstream` and the optional config. -/
def resolve (cliDownstream : Option String) : IO (System.FilePath × Option T) := do
  match cliDownstream with
  | some d =>
    let path ← IO.FS.realPath d
    let cfgFile := path / ".upstreamer"
    if (← cfgFile.pathExists) then
      return (path, some (resolveRelativePaths path (← loadFile cfgFile)))
    else
      return (path, none)
  | none =>
    let cwd ← IO.FS.realPath "."
    match (← walkUp cwd) with
    | some (dir, cfg) => return (dir, some cfg)
    | none => return (cwd, none)

end Upstreamer.Config
