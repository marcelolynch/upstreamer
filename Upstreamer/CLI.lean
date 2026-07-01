/-
Command-line surface for `upstreamer`, built on `leanprover/lean4-cli`.

The tool is upstream-agnostic. The `--preset mathlib` flag (or
`preset = mathlib` in `.upstreamer`) supplies sensible defaults for the
common case of upstreaming to leanprover-community/mathlib4. Without a
preset, the user must specify `--upstream-name` and `--upstream-namespace`
themselves (the path can come from `--upstream-path` or the config).

Resolution order for every option (lowest to highest precedence):
  preset default  →  .upstreamer config value  →  CLI flag.
-/
import Cli
import Upstreamer.Workflow
import Upstreamer.Stage
import Upstreamer.Commit
import Upstreamer.Revert
import Upstreamer.Build
import Upstreamer.Baseline
import Upstreamer.Config
import Upstreamer.Preset

open Cli

namespace Upstreamer.CLI

/-- Common, fully-resolved inputs every subcommand needs. -/
structure ResolvedCommon where
  downstream         : System.FilePath
  upstreamPath       : String
  upstreamName       : String
  upstreamNamespace  : String
  searchRootSegments : List String
  /-- Resolved staging-area namespace from CLI/config (or `none`, meaning
      "auto-detect using `searchRootSegments`"). -/
  searchRoot         : Option String
  cfg                : Option Config.T

/-- Pick the active preset. CLI `--preset` wins over config's `preset`. -/
private def pickPreset (p : Parsed) (cfg : Option Config.T) : Preset.T :=
  let name := (p.flag? "preset").map (·.as! String)
    |>.orElse fun _ => cfg.bind (·.preset)
  match name with
  | none => Preset.empty
  | some n => (Preset.byName? n).getD Preset.empty

/-- Resolve all common inputs. Each field falls back from CLI → config → preset. -/
def resolveCommon (p : Parsed) (cmdLabel : String)
    : IO (Sum UInt32 ResolvedCommon) := do
  let cliDownstream := (p.flag? "downstream").map (·.as! String)
  let (downstream, cfg) ← Config.resolve cliDownstream
  let preset := pickPreset p cfg
  -- upstream-path: CLI > config > error.
  let upstreamPathOpt :=
    (p.flag? "upstream-path").map (·.as! String)
      |>.orElse fun _ => cfg.bind (·.upstreamPath)
  let some upstreamPath := upstreamPathOpt
    | IO.eprintln s!"upstreamer{cmdLabel}: missing required --upstream-path <path> (or `upstream-path = ...` in .upstreamer)"
      return .inl 2
  -- upstream-name: CLI > config > preset > error.
  let upstreamNameOpt :=
    (p.flag? "upstream-name").map (·.as! String)
      |>.orElse fun _ => cfg.bind (·.upstreamName)
      |>.orElse fun _ => preset.upstreamName
  let some upstreamName := upstreamNameOpt
    | IO.eprintln s!"upstreamer{cmdLabel}: missing required --upstream-name <name> (or set it in .upstreamer, or use --preset mathlib)"
      return .inl 2
  -- upstream-namespace: CLI > config > preset > error.
  let upstreamNsOpt :=
    (p.flag? "upstream-namespace").map (·.as! String)
      |>.orElse fun _ => cfg.bind (·.upstreamNamespace)
      |>.orElse fun _ => preset.upstreamNamespace
  let some upstreamNamespace := upstreamNsOpt
    | IO.eprintln s!"upstreamer{cmdLabel}: missing required --upstream-namespace <name> (or set it in .upstreamer, or use --preset mathlib)"
      return .inl 2
  -- search-root: CLI > config > none (auto-detect).
  let searchRoot :=
    (p.flag? "search-root").map (·.as! String)
      |>.orElse fun _ => cfg.bind (·.searchRoot)
  -- searchRootSegments comes from the preset (no flag/config for it in v1).
  let searchRootSegments := preset.searchRootSegments
  return .inr {
    downstream, upstreamPath, upstreamName, upstreamNamespace,
    searchRoot, searchRootSegments, cfg
  }

/-- Build a `Workflow.Options` from a parsed command line and resolved common fields. -/
def parseWorkflowOpts (p : Parsed) (cmdLabel : String) : IO (Sum UInt32 Workflow.Options) := do
  match (← resolveCommon p cmdLabel) with
  | .inl ec => return .inl ec
  | .inr c =>
    let candidate : String := p.positionalArg! "candidate" |>.as! String
    let target : Option String := (p.flag? "target").map (·.as! String)
    let noVerifyClean : Bool := p.hasFlag "no-verify-clean"
    let verbose : Bool := p.hasFlag "verbose"
    let replaceImports : Bool := p.hasFlag "replace-imports"
    return .inr {
      candidate,
      downstream := c.downstream.toString,
      upstreamPath := c.upstreamPath,
      upstreamName := c.upstreamName,
      upstreamNamespace := c.upstreamNamespace,
      target,
      searchRoot := c.searchRoot,
      searchRootSegments := c.searchRootSegments,
      noVerifyClean,
      verbose,
      replaceImports
    }

/-- Run callback for the default (validate) phase. -/
def runUpstreamer (p : Parsed) : IO UInt32 := do
  match (← parseWorkflowOpts p "") with
  | .inl ec => return ec
  | .inr opts =>
    try Workflow.run opts; return 0
    catch e => IO.eprintln s!"upstreamer: {e}"; return 1

/-- Run callback for the `stage` phase. -/
def runStage (p : Parsed) : IO UInt32 := do
  match (← parseWorkflowOpts p " stage") with
  | .inl ec => return ec
  | .inr opts =>
    let dryRun := p.hasFlag "dry-run"
    try Stage.run opts dryRun; return 0
    catch e => IO.eprintln s!"upstreamer stage: {e}"; return 1

/-- The `stage` subcommand. -/
def stageCmd : Cmd := `[Cli|
  stage VIA runStage;
  "Set up the post-validate workspace state — copy candidate, redirect lakefile, \
   write re-export stub — but skip both builds. Use to iterate (edits + `build`) \
   before paying for an initial build verification."

  FLAGS:
    "downstream"          : String;  "Downstream project root. Default: walk up from CWD looking for .upstreamer."
    "upstream-path"       : String;  "Local clone of the upstream library. Required (here or in .upstreamer)."
    "upstream-name"       : String;  "Lakefile dep name (e.g. `mathlib`). Required if no preset."
    "upstream-namespace"  : String;  "Upstream namespace prefix (e.g. `Mathlib`). Required if no preset."
    "preset"              : String;  "Apply a preset's defaults (currently only `mathlib`)."
    "target"              : String;  "Override the destination inside the upstream — `.lean` path or dotted module name."
    "search-root"         : String;  "Override the staging-area namespace."
    "no-verify-clean";               "Skip the working-tree-clean refusal."
    "v", "verbose";                  "Stream `lake` build output live (otherwise captured and only shown on failure)."
    "replace-imports";               "Instead of writing a re-export stub, delete the candidate and rewrite consumer imports to the upstreamed module."
    "dry-run";                       "Phases 0–2 only; report what would happen, no files touched."

  ARGS:
    candidate : String; "The .lean file to upstream — file path or dotted module name."
]

/-- Run callback for the `commit` phase. -/
def runCommit (p : Parsed) : IO UInt32 := do
  match (← resolveCommon p " commit") with
  | .inl ec => return ec
  | .inr c =>
    let branch : Option String := (p.flag? "branch").map (·.as! String)
    let opts : Commit.Options := {
      downstream := c.downstream.toString,
      upstreamPath := c.upstreamPath,
      branch,
      upstreamNamespace := c.upstreamNamespace,
      upstreamName := c.upstreamName
    }
    try Commit.run opts; return 0
    catch e => IO.eprintln s!"upstreamer commit: {e}"; return 1

/-- The `commit` subcommand. -/
def commitCmd : Cmd := `[Cli|
  commit VIA runCommit;
  "Stage two PR-ready branches from the post-validate state. Run after \
   `upstreamer <candidate>` (or `stage` + `build`) succeeds. The \
   downstream commit reflects whatever shape validate/stage left the \
   workspace in (stub by default, or replaced if `--replace-imports` \
   was passed). Reads the candidate from `git status` — no argument needed."

  FLAGS:
    "downstream"         : String; "Downstream project root."
    "upstream-path"      : String; "Local upstream clone (or in .upstreamer)."
    "upstream-name"      : String; "Lakefile dep name (or via preset/.upstreamer)."
    "upstream-namespace" : String; "Upstream namespace (or via preset/.upstreamer)."
    "preset"             : String; "Apply a preset's defaults (e.g. `mathlib`)."
    "branch"             : String; "Branch name for both repos. Default: upstream/<basename>."
]

/-- Run callback for the `revert` phase. -/
def runRevert (p : Parsed) : IO UInt32 := do
  match (← resolveCommon p " revert") with
  | .inl ec => return ec
  | .inr c =>
    let opts : Revert.Options := {
      downstream := c.downstream.toString,
      upstreamPath := c.upstreamPath,
      upstreamNamespace := c.upstreamNamespace
    }
    try Revert.run opts; return 0
    catch e => IO.eprintln s!"upstreamer revert: {e}"; return 1

/-- The `revert` subcommand. -/
def revertCmd : Cmd := `[Cli|
  revert VIA runRevert;
  "Undo everything `validate`/`stage` did, returning both repos to the pre-validate state."

  FLAGS:
    "downstream"         : String; "Downstream project root."
    "upstream-path"      : String; "Local upstream clone."
    "upstream-name"      : String; "Lakefile dep name (or via preset)."
    "upstream-namespace" : String; "Upstream namespace (or via preset)."
    "preset"             : String; "Apply a preset's defaults."
]

/-- Run callback for the `build` phase. -/
def runBuild (p : Parsed) : IO UInt32 := do
  match (← resolveCommon p " build") with
  | .inl ec => return ec
  | .inr c =>
    let verbose : Bool := p.hasFlag "verbose"
    let opts : Build.Options := {
      downstream := c.downstream.toString,
      upstreamPath := c.upstreamPath,
      upstreamNamespace := c.upstreamNamespace,
      verbose
    }
    try Build.run opts; return 0
    catch e => IO.eprintln s!"upstreamer build: {e}"; return 1

/-- The `build` subcommand. -/
def buildCmd : Cmd := `[Cli|
  build VIA runBuild;
  "Run the upstream and downstream builds against the staged workspace, \
   without re-copying or re-rewriting anything. Use after `stage` (or after \
   editing the upstreamed file) to verify both sides still build."

  FLAGS:
    "downstream"         : String; "Downstream project root."
    "upstream-path"      : String; "Local upstream clone."
    "upstream-name"      : String; "Lakefile dep name (or via preset)."
    "upstream-namespace" : String; "Upstream namespace (or via preset)."
    "preset"             : String; "Apply a preset's defaults."
    "v", "verbose";                "Stream `lake` build output live (otherwise captured and only shown on failure)."
]

/-- Run callback for the `baseline` phase. -/
def runBaseline (p : Parsed) : IO UInt32 := do
  match (← resolveCommon p " baseline") with
  | .inl ec => return ec
  | .inr c =>
    let verbose : Bool := p.hasFlag "verbose"
    let opts : Baseline.Options := {
      downstream := c.downstream.toString,
      upstreamPath := c.upstreamPath,
      upstreamName := c.upstreamName,
      verbose
    }
    try Baseline.run opts; return 0
    catch e => IO.eprintln s!"upstreamer baseline: {e}"; return 1

/-- The `baseline` subcommand. -/
def baselineCmd : Cmd := `[Cli|
  baseline VIA runBaseline;
  "Pre-flight: does the downstream build against the local upstream AS-IS, \
   without any candidate? Restores lakefile + manifest no matter how the build went."

  FLAGS:
    "downstream"     : String; "Downstream project root."
    "upstream-path"  : String; "Local upstream clone."
    "upstream-name"  : String; "Lakefile dep name (or via preset)."
    "preset"         : String; "Apply a preset's defaults."
    "v", "verbose";            "Stream `lake` build output live (otherwise captured and only shown on failure)."
]

/-- The top-level command. `lake exe upstreamer --help` prints a usage block. -/
def upstreamerCmd : Cmd := `[Cli|
  upstreamer VIA runUpstreamer; ["0.4.0"]
  "Assist single-file upstreaming from a downstream project to an upstream library. \
   With no subcommand, runs the full validate workflow (audit + copy + upstream build + \
   redirect + stub + downstream build). Use `--preset mathlib` for the common case \
   (Lean projects upstreaming to leanprover-community/mathlib4) to fill in \
   `upstream-name`, `upstream-namespace`, and search-root auto-detection. \
   See README.md, DEMO.md, SCENARIOS.md for the full design."

  FLAGS:
    "downstream"          : String; "Downstream project root. Default: walk up from CWD looking for .upstreamer."
    "upstream-path"       : String; "Local clone of the upstream library. Required (or in .upstreamer)."
    "upstream-name"       : String; "Lakefile dep name (e.g. `mathlib`). Required if no preset."
    "upstream-namespace"  : String; "Upstream namespace prefix (e.g. `Mathlib`). Required if no preset."
    "preset"              : String; "Apply a preset's defaults (currently only `mathlib`). CLI and config still override."
    "target"              : String; "Override the destination inside the upstream — `.lean` path or dotted module name."
    "search-root"         : String; "Override the staging-area namespace. Auto-detected via the preset's segments otherwise."
    "no-verify-clean";              "Skip the working-tree-clean refusal."
    "v", "verbose";                 "Stream `lake` build output live (otherwise captured and only shown on failure)."

  ARGS:
    candidate : String; "The .lean file to upstream — file path (absolute or relative to CWD) or a dotted Lean module name (e.g. Carleson.ToMathlib.MinLayer) resolved against --downstream."

  SUBCOMMANDS:
    baselineCmd;
    stageCmd;
    commitCmd;
    revertCmd;
    buildCmd
]

end Upstreamer.CLI
