/-
Library root for the `Upstreamer` Lean library. Re-exports every public module
so consumers can `import Upstreamer` instead of pulling specific submodules.
-/
import Upstreamer.Util
import Upstreamer.Git
import Upstreamer.ImportScan
import Upstreamer.CLI
import Upstreamer.Workflow
