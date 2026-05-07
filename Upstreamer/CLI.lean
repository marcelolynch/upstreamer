/-
Command-line surface for `upstreamer`, built on `leanprover/lean4-cli`.
The `[Cli| ...]` DSL handles parsing, --help, --version, and short-flag
grouping; we only have to wire the parsed flags into `Workflow.Options`.
-/
import Cli
import Upstreamer.Workflow

open Cli

namespace Upstreamer.CLI

/-- Run callback dispatched by `Cli.Cmd.validate`. Translates `Parsed` flags
    into a `Workflow.Options` and runs the workflow, mapping exceptions to
    nonzero exit codes. -/
def runUpstreamer (p : Parsed) : IO UInt32 := do
  let candidate : String := p.positionalArg! "candidate" |>.as! String
  let some mathlibFlag := p.flag? "mathlib"
    | IO.eprintln "upstreamer: missing required --mathlib <path> (run with --help for usage)"
      return 2
  let mathlib : String := mathlibFlag.as! String
  let downstream : String :=
    (p.flag? "downstream").map (·.as! String) |>.getD "."
  let target : Option String := (p.flag? "target").map (·.as! String)
  let searchRoot : Option String := (p.flag? "search-root").map (·.as! String)
  let noVerifyClean : Bool := p.hasFlag "no-verify-clean"
  let dryRun : Bool := p.hasFlag "dry-run"
  let opts : Workflow.Options :=
    { candidate, downstream, mathlib, target, searchRoot, noVerifyClean, dryRun }
  try
    Workflow.run opts
    return 0
  catch e =>
    IO.eprintln s!"upstreamer: {e}"
    return 1

/-- The top-level command. `lake exe upstreamer --help` prints a fully
    auto-generated usage block from this declaration. -/
def upstreamerCmd : Cmd := `[Cli|
  upstreamer VIA runUpstreamer; ["0.1.0"]
  "Assist single-file upstreaming from a downstream project (e.g. Carleson) to Mathlib. \
   Copies the candidate into a local Mathlib checkout, builds it, redirects the \
   downstream's mathlib dependency at the local path, replaces the candidate with a \
   `module / public import` re-export stub, and rebuilds the downstream. \
   See the README for the full eight-phase workflow."

  FLAGS:
    "downstream"       : String; "Path to the downstream project root. Default: \".\"."
    "mathlib"          : String; "Path to a local mathlib4 clone. Required."
    "target"           : String; "Override the destination path inside Mathlib (e.g. Mathlib/Order/MinLayer.lean). Default: mirror of the candidate's path under the search root."
    "search-root"      : String; "Override the staging-area namespace (e.g. Carleson.ToMathlib). Auto-detected by default from a Mathlib/ToMathlib path component."
    "no-verify-clean";           "Skip the working-tree-clean refusal."
    "dry-run";                   "Run only Phases 0–2 (path mapping, commit-mismatch warning, import audit) and report what would happen. No files are touched. Useful for batch sanity checks across many candidates."

  ARGS:
    candidate : String; "Path to the .lean file to upstream (absolute or relative to CWD)."
]

end Upstreamer.CLI
