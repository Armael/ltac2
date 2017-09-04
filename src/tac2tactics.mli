(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Names
open Locus
open Globnames
open Tac2expr
open EConstr
open Genredexpr
open Misctypes
open Tactypes
open Proofview

type destruction_arg = EConstr.constr with_bindings tactic Misctypes.destruction_arg

(** Local reimplementations of tactics variants from Coq *)

val apply : advanced_flag -> evars_flag ->
  EConstr.constr with_bindings tactic list ->
  (Id.t * intro_pattern option) option -> unit tactic

type induction_clause =
  destruction_arg *
  intro_pattern_naming option *
  or_and_intro_pattern option *
  clause option

val induction_destruct : rec_flag -> evars_flag ->
  induction_clause list -> EConstr.constr with_bindings option -> unit tactic

type rewriting =
  bool option *
  multi *
  EConstr.constr with_bindings tactic

val rewrite :
  evars_flag -> rewriting list -> clause -> unit tactic option -> unit tactic

val simpl : global_reference glob_red_flag ->
  (Pattern.constr_pattern * occurrences_expr) option -> clause -> unit tactic

val cbv : global_reference glob_red_flag -> clause -> unit tactic

val cbn : global_reference glob_red_flag -> clause -> unit tactic

val lazy_ : global_reference glob_red_flag -> clause -> unit tactic

val unfold : (global_reference * occurrences_expr) list -> clause -> unit tactic

val vm : (Pattern.constr_pattern * occurrences_expr) option -> clause -> unit tactic

val native : (Pattern.constr_pattern * occurrences_expr) option -> clause -> unit tactic

val eval_red : backtrace -> constr -> constr tactic

val eval_hnf : backtrace -> constr -> constr tactic

val eval_simpl : backtrace -> global_reference glob_red_flag ->
  (Pattern.constr_pattern * occurrences_expr) option -> constr -> constr tactic

val eval_cbv : backtrace -> global_reference glob_red_flag -> constr -> constr tactic

val eval_cbn : backtrace -> global_reference glob_red_flag -> constr -> constr tactic

val eval_lazy : backtrace -> global_reference glob_red_flag -> constr -> constr tactic

val eval_unfold : backtrace -> (global_reference * occurrences_expr) list -> constr -> constr tactic

val eval_fold : backtrace -> constr list -> constr -> constr tactic

val eval_pattern : backtrace -> (EConstr.t * occurrences_expr) list -> constr -> constr tactic

val eval_vm : backtrace -> (Pattern.constr_pattern * occurrences_expr) option -> constr -> constr tactic

val eval_native : backtrace -> (Pattern.constr_pattern * occurrences_expr) option -> constr -> constr tactic

val discriminate : evars_flag -> destruction_arg option -> unit tactic

val injection : evars_flag -> intro_pattern list option -> destruction_arg option -> unit tactic

val autorewrite : all:bool -> unit tactic option -> Id.t list -> clause -> unit tactic

val trivial : Hints.debug -> constr tactic list -> Id.t list option ->
  unit Proofview.tactic

val auto : Hints.debug -> int option -> constr tactic list ->
  Id.t list option -> unit Proofview.tactic

val new_auto : Hints.debug -> int option -> constr tactic list ->
  Id.t list option -> unit Proofview.tactic

val eauto : Hints.debug -> int option -> int option -> constr tactic list ->
  Id.t list option -> unit Proofview.tactic

val typeclasses_eauto : Class_tactics.search_strategy -> int option ->
  Id.t list option -> unit Proofview.tactic
