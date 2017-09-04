(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Loc
open Names
open Tac2dyn
open Tac2qexpr
open Tac2expr

(** Syntactic quoting of expressions. *)

(** Contrarily to Tac2ffi, which lives on the semantic level, this module
    manipulates pure syntax of Ltac2. Its main purpose is to write notations. *)

val constructor : ?loc:Loc.t -> ltac_constructor -> raw_tacexpr list -> raw_tacexpr

val of_anti : ('a -> raw_tacexpr) -> 'a or_anti -> raw_tacexpr

val of_int : int located -> raw_tacexpr

val of_pair : ('a -> raw_tacexpr) -> ('b -> raw_tacexpr) -> ('a * 'b) located -> raw_tacexpr

val of_tuple : ?loc:Loc.t -> raw_tacexpr list -> raw_tacexpr

val of_variable : Id.t located -> raw_tacexpr

val of_ident : Id.t located -> raw_tacexpr

val of_constr : Constrexpr.constr_expr -> raw_tacexpr

val of_open_constr : Constrexpr.constr_expr -> raw_tacexpr

val of_list : ?loc:Loc.t -> ('a -> raw_tacexpr) -> 'a list -> raw_tacexpr

val of_bindings : bindings -> raw_tacexpr

val of_intro_pattern : intro_pattern -> raw_tacexpr

val of_intro_patterns : intro_pattern list located -> raw_tacexpr

val of_clause : clause -> raw_tacexpr

val of_destruction_arg : destruction_arg -> raw_tacexpr

val of_induction_clause : induction_clause -> raw_tacexpr

val of_rewriting : rewriting -> raw_tacexpr

val of_occurrences : occurrences -> raw_tacexpr

val of_reference : Libnames.reference or_anti -> raw_tacexpr

val of_hyp : ?loc:Loc.t -> Id.t located -> raw_tacexpr
(** id ↦ 'Control.hyp @id' *)

val of_exact_hyp : ?loc:Loc.t -> Id.t located -> raw_tacexpr
(** id ↦ 'Control.refine (fun () => Control.hyp @id') *)

val of_exact_var : ?loc:Loc.t -> Id.t located -> raw_tacexpr
(** id ↦ 'Control.refine (fun () => Control.hyp @id') *)

val of_dispatch : dispatch -> raw_tacexpr

val of_strategy_flag : strategy_flag -> raw_tacexpr

val of_constr_matching : constr_matching -> raw_tacexpr

(** {5 Generic arguments} *)

val wit_pattern : (Constrexpr.constr_expr, Pattern.constr_pattern) Arg.tag

val wit_ident : (Id.t, Id.t) Arg.tag

val wit_reference : (Libnames.reference, Globnames.global_reference) Arg.tag
(** Beware, at the raw level, [Qualid [id]] has not the same meaning as
    [Ident id]. The first is an unqualified global reference, the second is
    the dynamic reference to id. *)

val wit_constr : (Constrexpr.constr_expr, Glob_term.glob_constr) Arg.tag

val wit_open_constr : (Constrexpr.constr_expr, Glob_term.glob_constr) Arg.tag

val wit_ltac1 : (Tacexpr.raw_tactic_expr, Tacexpr.glob_tactic_expr) Arg.tag
