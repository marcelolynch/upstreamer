/-
Copyright (c) 2026 Marcelo Lynch. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Marcelo Lynch
-/
/-
Entry point for the `upstreamer` executable. The Cli library handles --help,
--version, parse errors, and short-flag grouping for us; all of the workflow
logic lives in `Upstreamer.CLI.runUpstreamer`.
-/
import Upstreamer.CLI

open Upstreamer

def main (args : List String) : IO UInt32 :=
  CLI.upstreamerCmd.validate args
