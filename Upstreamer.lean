/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
Library root for the `Upstreamer` Lean library. Re-exports every public module
so consumers can `import Upstreamer` instead of pulling specific submodules.
-/
import Upstreamer.Util
import Upstreamer.Git
import Upstreamer.ImportScan
import Upstreamer.ImportRewrite
import Upstreamer.CLI
import Upstreamer.Workflow
import Upstreamer.Stage
import Upstreamer.Commit
import Upstreamer.Revert
import Upstreamer.Build
import Upstreamer.Baseline
import Upstreamer.Config
import Upstreamer.Preset
import Upstreamer.State
