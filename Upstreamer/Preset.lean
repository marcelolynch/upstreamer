/-
Presets supply defaults for several options at once. Activated via
`--preset <name>` or `preset = <name>` in `.upstreamer`.

The tool itself is upstream-agnostic. Without a preset, the user must
supply `upstream-name`, `upstream-namespace`, and `search-root`
explicitly. The `mathlib` preset wires them up for the common case of
upstreaming to `leanprover-community/mathlib4`.

Resolution: preset values are the lowest-priority defaults; config
values override them; CLI flags override everything.
-/

namespace Upstreamer.Preset

/-- The defaults a preset supplies. `none` means "preset has no opinion
    — fall back to config / CLI / error". -/
structure T where
  /-- The dependency name in the downstream's lakefile (e.g. `"mathlib"`
      for `[[require]] name = "mathlib"`). -/
  upstreamName       : Option String := none
  /-- The upstream library's root namespace (e.g. `"Mathlib"`). -/
  upstreamNamespace  : Option String := none
  /-- Path-component names that mark the staging-area boundary during
      `--search-root` auto-detection. With `["Mathlib", "ToMathlib"]`,
      `Carleson/ToMathlib/Foo.lean` resolves to search-root
      `Carleson.ToMathlib`. Empty list ⇒ no auto-detection. -/
  searchRootSegments : List String := []
  deriving Repr

/-- The `mathlib` preset: targets leanprover-community/mathlib4. -/
def mathlib : T where
  upstreamName       := some "mathlib"
  upstreamNamespace  := some "Mathlib"
  searchRootSegments := ["Mathlib", "ToMathlib"]

/-- Look up a preset by name. -/
def byName? : String → Option T
  | "mathlib" => some mathlib
  | _ => none

/-- The empty preset (no opinions). Used when the user hasn't selected one. -/
def empty : T := {}

end Upstreamer.Preset
