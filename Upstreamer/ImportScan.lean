/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
Line-based scanner for `import` / `public import` directives in a .lean file.
Used to refuse upstreaming up front when a candidate depends on sibling
staging files or other downstream code.
-/

namespace Upstreamer.ImportScan

structure ImportLine where
  /-- The dotted module name being imported, e.g. "Mathlib.Order.MinLayer". -/
  module  : String
  /-- 1-based line number, for diagnostics. -/
  lineNo  : Nat
  /-- The original source line (whitespace preserved). -/
  raw     : String
  deriving Repr

/-- Default allowed module-name prefixes — what every Mathlib-flavored
    project tends to be allowed to import. The upstream namespace itself
    (e.g. `Mathlib`) is also unioned in by callers. -/
def defaultAllowedPrefixes : List String :=
  ["Mathlib", "Init", "Std", "Lean", "Batteries", "Aesop", "Qq", "ProofWidgets",
   "ImportGraph", "LeanSearchClient", "Plausible"]

/-- Strip `public ` / `private ` / `meta ` modifiers from a line, if present. -/
private def stripModifier (s : String) : String :=
  if s.startsWith "public "       then (s.drop "public ".length).copy
  else if s.startsWith "private " then (s.drop "private ".length).copy
  else if s.startsWith "meta "    then (s.drop "meta ".length).copy
  else s

/-- Try to parse a single source line as an import directive. Returns `none`
    for non-import lines (blank, comments, code). -/
def parseImport? (rawLine : String) (lineNo : Nat) : Option ImportLine := Id.run do
  -- Trim leading whitespace; preserve original for diagnostics.
  let stripped := rawLine.trimAsciiStart.copy
  -- Skip line-comments and blank lines fast.
  if stripped.startsWith "--" || stripped.isEmpty then return none
  let afterModifier := stripModifier stripped
  if !afterModifier.startsWith "import " then return none
  let afterImport := (afterModifier.drop "import ".length).trimAsciiStart.copy
  -- Module names: alphanumerics, underscores, dots. Stop on whitespace, comment,
  -- or end of line.
  let module := (afterImport.takeWhile (fun c =>
    c.isAlphanum || c == '_' || c == '.')).copy
  if module.isEmpty then return none
  return some { module, lineNo, raw := rawLine }

/-- Extract every import directive from file contents. -/
def extractImports (contents : String) : Array ImportLine := Id.run do
  let mut acc : Array ImportLine := #[]
  let mut lineNo := 1
  for rawLine in contents.splitOn "\n" do
    -- `parseImport?` already trims and ignores trailing whitespace/CRs because
    -- module names stop at any non-alphanumeric character.
    if let some imp := parseImport? rawLine lineNo then
      acc := acc.push imp
    lineNo := lineNo + 1
  return acc

/-- Does `mod` belong to namespace `ns` (i.e. equal to `ns` or starting with `ns.`)? -/
def inNamespace (ns : String) (mod : String) : Bool :=
  mod == ns || mod.startsWith (ns ++ ".")

/-- Classify each import in `imports`, returning ones that block upstreaming.
    The return value is a pair `(stagingViolations, projectViolations)`:
    * `stagingViolations` — imports of the staging namespace
    * `projectViolations` — other downstream-internal imports
    Either being non-empty is a hard refusal. The `allowedPrefixes` list
    decides what passes (typically `defaultAllowedPrefixes` ∪
    `[upstreamNamespace]`). -/
def classifyImports
    (projectName : String)
    (stagingNamespaces : List String)  -- e.g. ["Carleson.ToMathlib"]
    (allowedPrefixes : List String)    -- e.g. ["Mathlib", "Init", "Std", …]
    (imports : Array ImportLine)
    : Array ImportLine × Array ImportLine := Id.run do
  let mut staging : Array ImportLine := #[]
  let mut project : Array ImportLine := #[]
  for imp in imports do
    -- Allowed prefixes (Mathlib, etc.) clear the import outright.
    if allowedPrefixes.any (inNamespace · imp.module) then
      continue
    -- Staging?
    if stagingNamespaces.any (inNamespace · imp.module) then
      staging := staging.push imp
      continue
    -- Else: anything within the project namespace is a project-internal import.
    if inNamespace projectName imp.module then
      project := project.push imp
      continue
    -- Otherwise: an unknown third-party module (e.g. Carleson depends on
    -- checkdecls). We let it pass — if it's not in mathlib's lakefile, mathlib
    -- won't build it and phase 5 will surface the error there.
    pure ()
  return (staging, project)

end Upstreamer.ImportScan
