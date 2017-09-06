(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Names
open Tac2expr

val empty_environment : environment

val interp : environment -> glb_tacexpr -> valexpr Proofview.tactic

(* val interp_app : closure -> ml_tactic *)

(** {5 Cross-boundary encodings} *)

val get_env : Glob_term.unbound_ltac_var_map -> environment
val set_env : environment -> Glob_term.unbound_ltac_var_map -> Glob_term.unbound_ltac_var_map

(** {5 Exceptions} *)

exception LtacError of KerName.t * valexpr array * backtrace
(** Ltac2-defined exceptions seen from OCaml side *)

(** {5 Backtrace} *)

val get_backtrace : backtrace Proofview.tactic

val with_frame : frame -> 'a Proofview.tactic -> 'a Proofview.tactic

val print_ltac2_backtrace : bool ref
