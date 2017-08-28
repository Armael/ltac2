(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open CSig
open Pp
open Names
open Genarg
open Geninterp
open Tac2env
open Tac2expr
open Tac2interp
open Tac2entries.Pltac
open Proofview.Notations

(** Standard values *)

module Value = Tac2ffi

let std_core n = KerName.make2 Tac2env.std_prefix (Label.of_id (Id.of_string_soft n))
let coq_core n = KerName.make2 Tac2env.coq_prefix (Label.of_id (Id.of_string_soft n))

module Core =
struct

let t_int = coq_core "int"
let t_string = coq_core "string"
let t_array = coq_core "array"
let t_unit = coq_core "unit"
let t_list = coq_core "list"
let t_constr = coq_core "constr"
let t_pattern = coq_core "pattern"
let t_ident = coq_core "ident"
let t_option = coq_core "option"
let t_reference = std_core "reference"

let c_nil = coq_core "[]"
let c_cons = coq_core "::"

let c_none = coq_core "None"
let c_some = coq_core "Some"

let c_true = coq_core "true"
let c_false = coq_core "false"

end

open Core

let v_unit = ValInt 0

let of_name c = match c with
| Anonymous -> Value.of_option Value.of_ident None
| Name id -> Value.of_option Value.of_ident (Some id)

let of_instance sigma u =
  let u = Univ.Instance.to_array (EConstr.EInstance.kind sigma u) in
  Value.of_array (fun v -> Value.of_ext Value.val_univ v) u

let of_rec_declaration (nas, ts, cs) =
  (Value.of_array of_name nas,
  Value.of_array Value.of_constr ts,
  Value.of_array Value.of_constr cs)

let val_valexpr : valexpr Val.typ = Val.create "ltac2:valexpr"
let val_free : Id.Set.t Val.typ = Val.create "ltac2:free"

(** Stdlib exceptions *)

let err_notfocussed =
  LtacError (coq_core "Not_focussed", [||])

let err_outofbounds =
  LtacError (coq_core "Out_of_bounds", [||])

let err_notfound =
  LtacError (coq_core "Not_found", [||])

let err_matchfailure =
  LtacError (coq_core "Match_failure", [||])

(** Helper functions *)

let thaw f = interp_app f [v_unit]
let throw e = Proofview.tclLIFT (Proofview.NonLogical.raise e)

let return x = Proofview.tclUNIT x
let pname s = { mltac_plugin = "ltac2"; mltac_tactic = s }

let wrap f =
  return () >>= fun () -> return (f ())

let wrap_unit f =
  return () >>= fun () -> f (); return v_unit

let pf_apply f =
  Proofview.Goal.goals >>= function
  | [] ->
    Proofview.tclENV >>= fun env ->
    Proofview.tclEVARMAP >>= fun sigma ->
    f env sigma
  | [gl] ->
    gl >>= fun gl ->
    f (Proofview.Goal.env gl) (Tacmach.New.project gl)
  | _ :: _ :: _ ->
    throw err_notfocussed

(** Primitives *)

(** Printing *)

let prm_print : ml_tactic = function
| [pp] -> wrap_unit (fun () -> Feedback.msg_notice (Value.to_pp pp))
| _ -> assert false

let prm_message_of_int : ml_tactic = function
| [ValInt s] -> return (Value.of_pp (int s))
| _ -> assert false

let prm_message_of_string : ml_tactic = function
| [ValStr s] -> return (Value.of_pp (str (Bytes.to_string s)))
| _ -> assert false

let prm_message_of_constr : ml_tactic = function
| [c] ->
  pf_apply begin fun env sigma ->
    let c = Value.to_constr c in
    let pp = Printer.pr_econstr_env env sigma c in
    return (Value.of_pp pp)
  end
| _ -> assert false

let prm_message_of_ident : ml_tactic = function
| [c] ->
  let c = Value.to_ident c in
  let pp = Id.print c in
  return (Value.of_pp pp)
| _ -> assert false

let prm_message_concat : ml_tactic = function
| [m1; m2] ->
  let m1 = Value.to_pp m1 in
  let m2 = Value.to_pp m2 in
  return (Value.of_pp (Pp.app m1 m2))
| _ -> assert false

(** Array *)

let prm_array_make : ml_tactic = function
| [ValInt n; x] ->
  if n < 0 || n > Sys.max_array_length then throw err_outofbounds
  else wrap (fun () -> ValBlk (0, Array.make n x))
| _ -> assert false

let prm_array_length : ml_tactic = function
| [ValBlk (_, v)] -> return (ValInt (Array.length v))
| _ -> assert false

let prm_array_set : ml_tactic = function
| [ValBlk (_, v); ValInt n; x] ->
  if n < 0 || n >= Array.length v then throw err_outofbounds
  else wrap_unit (fun () -> v.(n) <- x)
| _ -> assert false

let prm_array_get : ml_tactic = function
| [ValBlk (_, v); ValInt n] ->
  if n < 0 || n >= Array.length v then throw err_outofbounds
  else wrap (fun () -> v.(n))
| _ -> assert false

(** Ident *)

let prm_ident_equal : ml_tactic = function
| [id1; id2] ->
  let id1 = Value.to_ident id1 in
  let id2 = Value.to_ident id2 in
  return (Value.of_bool (Id.equal id1 id2))
| _ -> assert false

let prm_ident_to_string : ml_tactic = function
| [id] ->
  let id = Value.to_ident id in
  return (Value.of_string (Id.to_string id))
| _ -> assert false

let prm_ident_of_string : ml_tactic = function
| [s] ->
  let s = Value.to_string s in
  let id = try Some (Id.of_string s) with _ -> None in
  return (Value.of_option Value.of_ident id)
| _ -> assert false

(** Int *)

let prm_int_equal : ml_tactic = function
| [m; n] ->
  return (Value.of_bool (Value.to_int m == Value.to_int n))
| _ -> assert false

let binop f : ml_tactic = function
| [m; n] -> return (Value.of_int (f (Value.to_int m) (Value.to_int n)))
| _ -> assert false

let prm_int_compare args = binop Int.compare args
let prm_int_add args = binop (+) args
let prm_int_sub args = binop (-) args
let prm_int_mul args = binop ( * ) args

let prm_int_neg : ml_tactic = function
| [m] -> return (Value.of_int (~- (Value.to_int m)))
| _ -> assert false

(** String *)

let prm_string_make : ml_tactic = function
| [n; c] ->
  let n = Value.to_int n in
  let c = Value.to_char c in
  if n < 0 || n > Sys.max_string_length then throw err_outofbounds
  else wrap (fun () -> Value.of_string (Bytes.make n c))
| _ -> assert false

let prm_string_length : ml_tactic = function
| [s] ->
  return (Value.of_int (Bytes.length (Value.to_string s)))
| _ -> assert false

let prm_string_set : ml_tactic = function
| [s; n; c] ->
  let s = Value.to_string s in
  let n = Value.to_int n in
  let c = Value.to_char c in
  if n < 0 || n >= Bytes.length s then throw err_outofbounds
  else wrap_unit (fun () -> Bytes.set s n c)
| _ -> assert false

let prm_string_get : ml_tactic = function
| [s; n] ->
  let s = Value.to_string s in
  let n = Value.to_int n in
  if n < 0 || n >= Bytes.length s then throw err_outofbounds
  else wrap (fun () -> Value.of_char (Bytes.get s n))
| _ -> assert false

(** Terms *)

(** constr -> constr *)
let prm_constr_type : ml_tactic = function
| [c] ->
  let c = Value.to_constr c in
  let get_type env sigma =
  Proofview.V82.wrap_exceptions begin fun () ->
    let (sigma, t) = Typing.type_of env sigma c in
    let t = Value.of_constr t in
    Proofview.Unsafe.tclEVARS sigma <*> Proofview.tclUNIT t
  end in
  pf_apply get_type
| _ -> assert false

(** constr -> constr *)
let prm_constr_equal : ml_tactic = function
| [c1; c2] ->
  let c1 = Value.to_constr c1 in
  let c2 = Value.to_constr c2 in
  Proofview.tclEVARMAP >>= fun sigma ->
  let b = EConstr.eq_constr sigma c1 c2 in
  Proofview.tclUNIT (Value.of_bool b)
| _ -> assert false

let prm_constr_kind : ml_tactic = function
| [c] ->
  let open Constr in
  Proofview.tclEVARMAP >>= fun sigma ->
  let c = Value.to_constr c in
  return begin match EConstr.kind sigma c with
  | Rel n ->
    ValBlk (0, [|Value.of_int n|])
  | Var id ->
    ValBlk (1, [|Value.of_ident id|])
  | Meta n ->
    ValBlk (2, [|Value.of_int n|])
  | Evar (evk, args) ->
    ValBlk (3, [|
      Value.of_int (Evar.repr evk);
      Value.of_array Value.of_constr args;
    |])
  | Sort s ->
    ValBlk (4, [|Value.of_ext Value.val_sort s|])
  | Cast (c, k, t) ->
    ValBlk (5, [|
      Value.of_constr c;
      Value.of_ext Value.val_cast k;
      Value.of_constr t;
    |])
  | Prod (na, t, u) ->
    ValBlk (6, [|
      of_name na;
      Value.of_constr t;
      Value.of_constr u;
    |])
  | Lambda (na, t, c) ->
    ValBlk (7, [|
      of_name na;
      Value.of_constr t;
      Value.of_constr c;
    |])
  | LetIn (na, b, t, c) ->
    ValBlk (8, [|
      of_name na;
      Value.of_constr b;
      Value.of_constr t;
      Value.of_constr c;
    |])
  | App (c, cl) ->
    ValBlk (9, [|
      Value.of_constr c;
      Value.of_array Value.of_constr cl;
    |])
  | Const (cst, u) ->
    ValBlk (10, [|
      Value.of_constant cst;
      of_instance sigma u;
    |])
  | Ind (ind, u) ->
    ValBlk (11, [|
      Value.of_ext Value.val_inductive ind;
      of_instance sigma u;
    |])
  | Construct (cstr, u) ->
    ValBlk (12, [|
      Value.of_ext Value.val_constructor cstr;
      of_instance sigma u;
    |])
  | Case (_, c, t, bl) ->
    ValBlk (13, [|
      Value.of_constr c;
      Value.of_constr t;
      Value.of_array Value.of_constr bl;
    |])
  | Fix ((recs, i), def) ->
    let (nas, ts, cs) = of_rec_declaration def in
    ValBlk (14, [|
      Value.of_array Value.of_int recs;
      Value.of_int i;
      nas;
      ts;
      cs;
    |])
  | CoFix (i, def) ->
    let (nas, ts, cs) = of_rec_declaration def in
    ValBlk (15, [|
      Value.of_int i;
      nas;
      ts;
      cs;
    |])
  | Proj (p, c) ->
    ValBlk (16, [|
      Value.of_ext Value.val_projection p;
      Value.of_constr c;
    |])
  end
| _ -> assert false

(** Patterns *)

let prm_pattern_matches : ml_tactic = function
| [pat; c] ->
  let pat = Value.to_pattern pat in
  let c = Value.to_constr c in
  pf_apply begin fun env sigma ->
    let ans =
      try Some (Constr_matching.matches env sigma pat c)
      with Constr_matching.PatternMatchingFailure -> None
    in
    begin match ans with
    | None -> Proofview.tclZERO err_matchfailure
    | Some ans ->
      let ans = Id.Map.bindings ans in
      let of_pair (id, c) = Value.of_tuple [| Value.of_ident id; Value.of_constr c |] in
      return (Value.of_list of_pair ans)
    end
  end
| _ -> assert false

let prm_pattern_matches_subterm : ml_tactic = function
| [pat; c] ->
  let pat = Value.to_pattern pat in
  let c = Value.to_constr c in
  let open Constr_matching in
  let rec of_ans s = match IStream.peek s with
  | IStream.Nil -> Proofview.tclZERO err_matchfailure
  | IStream.Cons ({ m_sub = (_, sub); m_ctx }, s) ->
    let ans = Id.Map.bindings sub in
    let of_pair (id, c) = Value.of_tuple [| Value.of_ident id; Value.of_constr c |] in
    let ans = Value.of_tuple [| Value.of_constr m_ctx; Value.of_list of_pair ans |] in
    Proofview.tclOR (return ans) (fun _ -> of_ans s)
  in
  pf_apply begin fun env sigma ->
    let ans = Constr_matching.match_appsubterm env sigma pat c in
    of_ans ans
  end
| _ -> assert false

let prm_pattern_instantiate : ml_tactic = function
| [ctx; c] ->
  let ctx = EConstr.Unsafe.to_constr (Value.to_constr ctx) in
  let c = EConstr.Unsafe.to_constr (Value.to_constr c) in
  let ans = Termops.subst_meta [Constr_matching.special_meta, c] ctx in
  return (Value.of_constr (EConstr.of_constr ans))
| _ -> assert false

(** Error *)

let prm_throw : ml_tactic = function
| [e] ->
  let (e, info) = Value.to_exn e in
  Proofview.tclLIFT (Proofview.NonLogical.raise ~info e)
| _ -> assert false

(** Control *)

(** exn -> 'a *)
let prm_zero : ml_tactic = function
| [e] ->
  let (e, info) = Value.to_exn e in
  Proofview.tclZERO ~info e
| _ -> assert false

(** (unit -> 'a) -> (exn -> 'a) -> 'a *)
let prm_plus : ml_tactic = function
| [x; k] ->
  Proofview.tclOR (thaw x) (fun e -> interp_app k [Value.of_exn e])
| _ -> assert false

(** (unit -> 'a) -> 'a *)
let prm_once : ml_tactic = function
| [f] -> Proofview.tclONCE (thaw f)
| _ -> assert false

(** (unit -> unit) list -> unit *)
let prm_dispatch : ml_tactic = function
| [l] ->
  let l = Value.to_list (fun f -> Proofview.tclIGNORE (thaw f)) l in
  Proofview.tclDISPATCH l >>= fun () -> return v_unit
| _ -> assert false

(** (unit -> unit) list -> (unit -> unit) -> (unit -> unit) list -> unit *)
let prm_extend : ml_tactic = function
| [lft; tac; rgt] ->
  let lft = Value.to_list (fun f -> Proofview.tclIGNORE (thaw f)) lft in
  let tac = Proofview.tclIGNORE (thaw tac) in
  let rgt = Value.to_list (fun f -> Proofview.tclIGNORE (thaw f)) rgt in
  Proofview.tclEXTEND lft tac rgt >>= fun () -> return v_unit
| _ -> assert false

(** (unit -> unit) -> unit *)
let prm_enter : ml_tactic = function
| [f] ->
  let f = Proofview.tclIGNORE (thaw f) in
  Proofview.tclINDEPENDENT f >>= fun () -> return v_unit
| _ -> assert false

let k_var = Id.of_string "k"
let e_var = Id.of_string "e"
let prm_apply_kont_h = pname "apply_kont"

(** (unit -> 'a) -> ('a * ('exn -> 'a)) result *)
let prm_case : ml_tactic = function
| [f] ->
  Proofview.tclCASE (thaw f) >>= begin function
  | Proofview.Next (x, k) ->
    let k = {
      clos_env = Id.Map.singleton k_var (Value.of_ext Value.val_kont k);
      clos_var = [Name e_var];
      clos_exp = GTacPrm (prm_apply_kont_h, [GTacVar k_var; GTacVar e_var]);
    } in
    return (ValBlk (0, [| Value.of_tuple [| x; ValCls k |] |]))
  | Proofview.Fail e -> return (ValBlk (1, [| Value.of_exn e |]))
  end
| _ -> assert false

(** 'a kont -> exn -> 'a *)
let prm_apply_kont : ml_tactic = function
| [k; e] -> (Value.to_ext Value.val_kont k) (Value.to_exn e)
| _ -> assert false

(** int -> int -> (unit -> 'a) -> 'a *)
let prm_focus : ml_tactic = function
| [i; j; tac] ->
  let i = Value.to_int i in
  let j = Value.to_int j in
  Proofview.tclFOCUS i j (thaw tac)
| _ -> assert false

(** unit -> unit *)
let prm_shelve : ml_tactic = function
| [_] -> Proofview.shelve >>= fun () -> return v_unit
| _ -> assert false

(** unit -> unit *)
let prm_shelve_unifiable : ml_tactic = function
| [_] -> Proofview.shelve_unifiable >>= fun () -> return v_unit
| _ -> assert false

let prm_new_goal : ml_tactic = function
| [ev] ->
  let ev = Evar.unsafe_of_int (Value.to_int ev) in
  Proofview.tclEVARMAP >>= fun sigma ->
  if Evd.mem sigma ev then
    Proofview.Unsafe.tclNEWGOALS [ev] <*> Proofview.tclUNIT v_unit
  else throw err_notfound
| _ -> assert false

(** unit -> constr *)
let prm_goal : ml_tactic = function
| [_] ->
  Proofview.Goal.enter_one begin fun gl ->
    let concl = Tacmach.New.pf_nf_concl gl in
    return (Value.of_constr concl)
  end
| _ -> assert false

(** ident -> constr *)
let prm_hyp : ml_tactic = function
| [id] ->
  let id = Value.to_ident id in
  pf_apply begin fun env _ ->
    let mem = try ignore (Environ.lookup_named id env); true with Not_found -> false in
    if mem then return (Value.of_constr (EConstr.mkVar id))
    else Tacticals.New.tclZEROMSG
      (str "Hypothesis " ++ quote (Id.print id) ++ str " not found") (** FIXME: Do something more sensible *)
  end
| _ -> assert false

let prm_hyps : ml_tactic = function
| [_] ->
  pf_apply begin fun env _ ->
    let open Context.Named.Declaration in
    let hyps = List.rev (Environ.named_context env) in
    let map = function
    | LocalAssum (id, t) ->
      let t = EConstr.of_constr t in
      Value.of_tuple [|Value.of_ident id; Value.of_option Value.of_constr None; Value.of_constr t|]
    | LocalDef (id, c, t) ->
      let c = EConstr.of_constr c in
      let t = EConstr.of_constr t in
      Value.of_tuple [|Value.of_ident id; Value.of_option Value.of_constr (Some c); Value.of_constr t|]
    in
    return (Value.of_list map hyps)
  end
| _ -> assert false

(** (unit -> constr) -> unit *)
let prm_refine : ml_tactic = function
| [c] ->
  let c = thaw c >>= fun c -> Proofview.tclUNIT ((), Value.to_constr c) in
  Proofview.Goal.nf_enter begin fun gl ->
    Refine.generic_refine ~typecheck:true c gl
  end >>= fun () -> return v_unit
| _ -> assert false

let prm_with_holes : ml_tactic = function
| [x; f] ->
  Proofview.tclEVARMAP >>= fun sigma0 ->
  thaw x >>= fun ans ->
  Proofview.tclEVARMAP >>= fun sigma ->
  Proofview.Unsafe.tclEVARS sigma0 >>= fun () ->
  Tacticals.New.tclWITHHOLES false (interp_app f [ans]) sigma
| _ -> assert false

let prm_progress : ml_tactic = function
| [f] -> Proofview.tclPROGRESS (thaw f)
| _ -> assert false

let prm_abstract : ml_tactic = function
| [id; f] ->
  let id = Value.to_option Value.to_ident id in
  Tactics.tclABSTRACT id (Proofview.tclIGNORE (thaw f)) >>= fun () ->
  return v_unit
| _ -> assert false

let prm_time : ml_tactic = function
| [s; f] ->
  let s = Value.to_option Value.to_string s in
  Proofview.tclTIME s (thaw f)
| _ -> assert false

let prm_check_interrupt : ml_tactic = function
| [_] -> Proofview.tclCHECKINTERRUPT >>= fun () -> return v_unit
| _ -> assert false

(** Fresh *)

let prm_free_union : ml_tactic = function
| [set1; set2] ->
  let set1 = Value.to_ext val_free set1 in
  let set2 = Value.to_ext val_free set2 in
  let ans = Id.Set.union set1 set2 in
  return (Value.of_ext val_free ans)
| _ -> assert false

let prm_free_of_ids : ml_tactic = function
| [ids] ->
  let ids = Value.to_list Value.to_ident ids in
  let free = List.fold_right Id.Set.add ids Id.Set.empty in
  return (Value.of_ext val_free free)
| _ -> assert false

let prm_free_of_constr : ml_tactic = function
| [c] ->
  let c = Value.to_constr c in
  Proofview.tclEVARMAP >>= fun sigma ->
  let rec fold accu c = match EConstr.kind sigma c with
  | Constr.Var id -> Id.Set.add id accu
  | _ -> EConstr.fold sigma fold accu c
  in
  let ans = fold Id.Set.empty c in
  return (Value.of_ext val_free ans)
| _ -> assert false

let prm_fresh : ml_tactic = function
| [avoid; id] ->
  let avoid = Value.to_ext val_free avoid in
  let id = Value.to_ident id in
  let nid = Namegen.next_ident_away_from id (fun id -> Id.Set.mem id avoid) in
  return (Value.of_ident nid)
| _ -> assert false

(** Registering *)

let () = Tac2env.define_primitive (pname "print") prm_print
let () = Tac2env.define_primitive (pname "message_of_string") prm_message_of_string
let () = Tac2env.define_primitive (pname "message_of_int") prm_message_of_int
let () = Tac2env.define_primitive (pname "message_of_constr") prm_message_of_constr
let () = Tac2env.define_primitive (pname "message_of_ident") prm_message_of_ident
let () = Tac2env.define_primitive (pname "message_concat") prm_message_concat

let () = Tac2env.define_primitive (pname "array_make") prm_array_make
let () = Tac2env.define_primitive (pname "array_length") prm_array_length
let () = Tac2env.define_primitive (pname "array_get") prm_array_get
let () = Tac2env.define_primitive (pname "array_set") prm_array_set

let () = Tac2env.define_primitive (pname "string_make") prm_string_make
let () = Tac2env.define_primitive (pname "string_length") prm_string_length
let () = Tac2env.define_primitive (pname "string_get") prm_string_get
let () = Tac2env.define_primitive (pname "string_set") prm_string_set

let () = Tac2env.define_primitive (pname "constr_type") prm_constr_type
let () = Tac2env.define_primitive (pname "constr_equal") prm_constr_equal
let () = Tac2env.define_primitive (pname "constr_kind") prm_constr_kind

let () = Tac2env.define_primitive (pname "pattern_matches") prm_pattern_matches
let () = Tac2env.define_primitive (pname "pattern_matches_subterm") prm_pattern_matches_subterm
let () = Tac2env.define_primitive (pname "pattern_instantiate") prm_pattern_instantiate

let () = Tac2env.define_primitive (pname "int_equal") prm_int_equal
let () = Tac2env.define_primitive (pname "int_compare") prm_int_compare
let () = Tac2env.define_primitive (pname "int_neg") prm_int_neg
let () = Tac2env.define_primitive (pname "int_add") prm_int_add
let () = Tac2env.define_primitive (pname "int_sub") prm_int_sub
let () = Tac2env.define_primitive (pname "int_mul") prm_int_mul

let () = Tac2env.define_primitive (pname "ident_equal") prm_ident_equal
let () = Tac2env.define_primitive (pname "ident_to_string") prm_ident_to_string
let () = Tac2env.define_primitive (pname "ident_of_string") prm_ident_of_string

let () = Tac2env.define_primitive (pname "throw") prm_throw

let () = Tac2env.define_primitive (pname "zero") prm_zero
let () = Tac2env.define_primitive (pname "plus") prm_plus
let () = Tac2env.define_primitive (pname "once") prm_once
let () = Tac2env.define_primitive (pname "dispatch") prm_dispatch
let () = Tac2env.define_primitive (pname "extend") prm_extend
let () = Tac2env.define_primitive (pname "enter") prm_enter
let () = Tac2env.define_primitive (pname "case") prm_case
let () = Tac2env.define_primitive (pname "apply_kont") prm_apply_kont

let () = Tac2env.define_primitive (pname "focus") prm_focus
let () = Tac2env.define_primitive (pname "shelve") prm_shelve
let () = Tac2env.define_primitive (pname "shelve_unifiable") prm_shelve_unifiable
let () = Tac2env.define_primitive (pname "new_goal") prm_new_goal
let () = Tac2env.define_primitive (pname "goal") prm_goal
let () = Tac2env.define_primitive (pname "hyp") prm_hyp
let () = Tac2env.define_primitive (pname "hyps") prm_hyps
let () = Tac2env.define_primitive (pname "refine") prm_refine
let () = Tac2env.define_primitive (pname "with_holes") prm_with_holes
let () = Tac2env.define_primitive (pname "progress") prm_progress
let () = Tac2env.define_primitive (pname "abstract") prm_abstract
let () = Tac2env.define_primitive (pname "time") prm_time
let () = Tac2env.define_primitive (pname "check_interrupt") prm_check_interrupt

let () = Tac2env.define_primitive (pname "fresh_fresh") prm_fresh
let () = Tac2env.define_primitive (pname "fresh_free_union") prm_free_union
let () = Tac2env.define_primitive (pname "fresh_free_of_ids") prm_free_of_ids
let () = Tac2env.define_primitive (pname "fresh_free_of_constr") prm_free_of_constr

(** ML types *)

let constr_flags () =
  let open Pretyping in
  {
    use_typeclasses = true;
    solve_unification_constraints = true;
    use_hook = Pfedit.solve_by_implicit_tactic ();
    fail_evar = true;
    expand_evars = true
  }

let open_constr_no_classes_flags () =
  let open Pretyping in
  {
  use_typeclasses = false;
  solve_unification_constraints = true;
  use_hook = Pfedit.solve_by_implicit_tactic ();
  fail_evar = false;
  expand_evars = true
  }

(** Embed all Ltac2 data into Values *)
let to_lvar ist =
  let open Glob_ops in
  let map e = Val.Dyn (val_valexpr, e) in
  let lfun = Id.Map.map map ist in
  { empty_lvar with Glob_term.ltac_genargs = lfun }

let interp_constr flags ist (c, _) =
  let open Pretyping in
  pf_apply begin fun env sigma ->
  Proofview.V82.wrap_exceptions begin fun () ->
    let ist = to_lvar ist in
    let (sigma, c) = understand_ltac flags env sigma ist WithoutTypeConstraint c in
    let c = ValExt (Value.val_constr, c) in
    Proofview.Unsafe.tclEVARS sigma >>= fun () ->
    Proofview.tclUNIT c
  end
  end

let () =
  let interp ist c = interp_constr (constr_flags ()) ist c in
  let obj = {
    ml_type = t_constr;
    ml_interp = interp;
  } in
  define_ml_object Stdarg.wit_constr obj

let () =
  let interp ist c = interp_constr (open_constr_no_classes_flags ()) ist c in
  let obj = {
    ml_type = t_constr;
    ml_interp = interp;
  } in
  define_ml_object Stdarg.wit_open_constr obj

let () =
  let interp _ id = return (ValExt (Value.val_ident, id)) in
  let obj = {
    ml_type = t_ident;
    ml_interp = interp;
  } in
  define_ml_object Stdarg.wit_ident obj

let () =
  let interp _ c = return (ValExt (Value.val_pattern, c)) in
  let obj = {
    ml_type = t_pattern;
    ml_interp = interp;
  } in
  define_ml_object Tac2env.wit_pattern obj

let () =
  let interp _ gr = return (Value.of_reference gr) in
  let obj = {
    ml_type = t_reference;
    ml_interp = interp;
  } in
  define_ml_object Tac2env.wit_reference obj

let () =
  let interp _ tac =
    (** FUCK YOU API *)
    (Obj.magic Ltac_plugin.Tacinterp.eval_tactic tac : unit Proofview.tactic) >>= fun () ->
    return v_unit
  in
  let obj = {
    ml_type = t_unit;
    ml_interp = interp;
  } in
  define_ml_object Ltac_plugin.Tacarg.wit_tactic obj

(** Ltac2 in terms *)

let () =
  let interp ist env sigma concl tac =
    let fold id (Val.Dyn (tag, v)) (accu : environment) : environment =
      match Val.eq tag val_valexpr with
      | None -> accu
      | Some Refl -> Id.Map.add id v accu
    in
    let ist = Id.Map.fold fold ist Id.Map.empty in
    let tac = Proofview.tclIGNORE (interp ist tac) in
    let c, sigma = Pfedit.refine_by_tactic env sigma concl tac in
    (EConstr.of_constr c, sigma)
  in
  Pretyping.register_constr_interp0 wit_ltac2 interp

(** Ltac2 in Ltac1 *)

let () =
  (** FUCK YOU API *)
  let e = (Obj.magic Tac2entries.Pltac.tac2expr : _ API.Pcoq.Gram.entry) in
  let inject (loc, v) = Tacexpr.TacGeneric (in_gen (rawwit wit_ltac2) v) in
  Ltac_plugin.Tacentries.create_ltac_quotation "ltac2" inject (e, None)

let () =
  let open Ltac_plugin in
  let open Tacinterp in
  let idtac = Value.of_closure (default_ist ()) (Tacexpr.TacId []) in
  (** FUCK YOU API *)
  let idtac = (Obj.magic idtac : Geninterp.Val.t) in
  let interp ist tac =
    Tac2interp.interp Tac2interp.empty_environment tac >>= fun _ ->
    Ftactic.return idtac
  in
  Geninterp.register_interp0 wit_ltac2 interp

(** Patterns *)

let () =
  let intern ist c =
    let _, pat = Constrintern.intern_constr_pattern ist.Genintern.genv ~as_type:false c in
    ist, pat
  in
  Genintern.register_intern0 wit_pattern intern

let () =
  let subst s c = Patternops.subst_pattern s c in
  Genintern.register_subst0 wit_pattern subst

(** References *)

let () =
  let intern ist qid = match qid with
  | Libnames.Ident (_, id) -> ist, Globnames.VarRef id
  | Libnames.Qualid (loc, qid) ->
    let gr =
      try Nametab.locate qid
      with Not_found ->
        Nametab.error_global_not_found ?loc qid
    in
    ist, gr
  in
  Genintern.register_intern0 wit_reference intern

let () =
  let subst s c = Globnames.subst_global_reference s c in
  Genintern.register_subst0 wit_reference subst

(** Built-in notation scopes *)

let add_scope s f =
  Tac2entries.register_scope (Id.of_string s) f

let scope_fail () = CErrors.user_err (str "Invalid parsing token")

let dummy_loc = Loc.make_loc (-1, -1)

let q_unit = CTacCst (dummy_loc, AbsKn (Tuple 0))

let rthunk e =
  let loc = Tac2intern.loc_of_tacexpr e in
  let var = [CPatVar (Some loc, Anonymous), Some (CTypRef (loc, AbsKn (Other Core.t_unit), []))] in
  CTacFun (loc, var, e)

let add_generic_scope s entry arg =
  let parse = function
  | [] ->
    let scope = Extend.Aentry entry in
    let act x = CTacExt (dummy_loc, in_gen (rawwit arg) x) in
    Tac2entries.ScopeRule (scope, act)
  | _ -> scope_fail ()
  in
  add_scope s parse

let () = add_scope "keyword" begin function
| [SexprStr (loc, s)] ->
  let scope = Extend.Atoken (Tok.KEYWORD s) in
  Tac2entries.ScopeRule (scope, (fun _ -> q_unit))
| _ -> scope_fail ()
end

let () = add_scope "terminal" begin function
| [SexprStr (loc, s)] ->
  let scope = Extend.Atoken (CLexer.terminal s) in
  Tac2entries.ScopeRule (scope, (fun _ -> q_unit))
| _ -> scope_fail ()
end

let () = add_scope "list0" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let scope = Extend.Alist0 scope in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| [tok; SexprStr (_, str)] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let sep = Extend.Atoken (CLexer.terminal str) in
  let scope = Extend.Alist0sep (scope, sep) in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let () = add_scope "list1" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let scope = Extend.Alist1 scope in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| [tok; SexprStr (_, str)] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let sep = Extend.Atoken (CLexer.terminal str) in
  let scope = Extend.Alist1sep (scope, sep) in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let () = add_scope "opt" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let scope = Extend.Aopt scope in
  let act opt = match opt with
  | None ->
    CTacCst (dummy_loc, AbsKn (Other Core.c_none))
  | Some x ->
    CTacApp (dummy_loc, CTacCst (dummy_loc, AbsKn (Other Core.c_some)), [act x])
  in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let () = add_scope "self" begin function
| [] ->
  let scope = Extend.Aself in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let () = add_scope "next" begin function
| [] ->
  let scope = Extend.Anext in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let () = add_scope "tactic" begin function
| [] ->
  (** Default to level 5 parsing *)
  let scope = Extend.Aentryl (tac2expr, 5) in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| [SexprInt (loc, n)] ->
  let () = if n < 0 || n > 6 then scope_fail () in
  let scope = Extend.Aentryl (tac2expr, n) in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let () = add_scope "thunk" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let act e = rthunk (act e) in
  Tac2entries.ScopeRule (scope, act)
| _ -> scope_fail ()
end

let add_expr_scope name entry f =
  add_scope name begin function
  | [] -> Tac2entries.ScopeRule (Extend.Aentry entry, f)
  | _ -> scope_fail ()
  end

let () = add_expr_scope "ident" q_ident (fun id -> Tac2quote.of_anti Tac2quote.of_ident id)
let () = add_expr_scope "bindings" q_bindings Tac2quote.of_bindings
let () = add_expr_scope "with_bindings" q_with_bindings Tac2quote.of_bindings
let () = add_expr_scope "intropattern" q_intropattern Tac2quote.of_intro_pattern
let () = add_expr_scope "intropatterns" q_intropatterns Tac2quote.of_intro_patterns
let () = add_expr_scope "induction_clause" q_induction_clause Tac2quote.of_induction_clause
let () = add_expr_scope "rewriting" q_rewriting Tac2quote.of_rewriting
let () = add_expr_scope "clause" q_clause Tac2quote.of_clause
let () = add_expr_scope "occurrences" q_occurrences Tac2quote.of_occurrences
let () = add_expr_scope "dispatch" q_dispatch Tac2quote.of_dispatch
let () = add_expr_scope "strategy" q_strategy_flag Tac2quote.of_strategy_flag
let () = add_expr_scope "reference" q_reference Tac2quote.of_reference

let () = add_generic_scope "constr" Pcoq.Constr.constr Stdarg.wit_constr
let () = add_generic_scope "open_constr" Pcoq.Constr.constr Stdarg.wit_open_constr
let () = add_generic_scope "pattern" Pcoq.Constr.constr wit_pattern

(** seq scope, a bit hairy *)

open Extend
exception SelfSymbol

type 'a any_symbol = { any_symbol : 'r. ('r, 'a) symbol }

let rec generalize_symbol :
  type a s. (s, a) Extend.symbol -> a any_symbol = function
| Atoken tok ->
  { any_symbol = Atoken tok }
| Alist1 e ->
  let e = generalize_symbol e in
  { any_symbol = Alist1 e.any_symbol }
| Alist1sep (e, sep) ->
  let e = generalize_symbol e in
  let sep = generalize_symbol sep in
  { any_symbol = Alist1sep (e.any_symbol, sep.any_symbol) }
| Alist0 e ->
  let e = generalize_symbol e in
  { any_symbol = Alist0 e.any_symbol }
| Alist0sep (e, sep) ->
  let e = generalize_symbol e in
  let sep = generalize_symbol sep in
  { any_symbol = Alist0sep (e.any_symbol, sep.any_symbol) }
| Aopt e ->
  let e = generalize_symbol e in
  { any_symbol = Aopt e.any_symbol }
| Aself -> raise SelfSymbol
| Anext -> raise SelfSymbol
| Aentry e -> { any_symbol = Aentry e }
| Aentryl (e, l) -> { any_symbol = Aentryl (e, l) }
| Arules r -> { any_symbol = Arules r }

type _ converter =
| CvNil : (Loc.t -> raw_tacexpr) converter
| CvCns : 'act converter * ('a -> raw_tacexpr) option -> ('a -> 'act) converter

let rec apply : type a. a converter -> raw_tacexpr list -> a = function
| CvNil -> fun accu loc -> Tac2quote.of_tuple ~loc accu
| CvCns (c, None) -> fun accu x -> apply c accu
| CvCns (c, Some f) -> fun accu x -> apply c (f x :: accu)

type seqrule =
| Seqrule : ('act, Loc.t -> raw_tacexpr) norec_rule * 'act converter -> seqrule

let rec make_seq_rule = function
| [] ->
  let r = { norec_rule = Stop } in
  Seqrule (r, CvNil)
| tok :: rem ->
  let Tac2entries.ScopeRule (scope, f) = Tac2entries.parse_scope tok in
  let scope = generalize_symbol scope in
  let Seqrule (r, c) = make_seq_rule rem in
  let r = { norec_rule = Next (r.norec_rule, scope.any_symbol) } in
  let f = match tok with
  | SexprStr _ -> None (** Leave out mere strings *)
  | _ -> Some f
  in
  Seqrule (r, CvCns (c, f))

let () = add_scope "seq" begin fun toks ->
  let scope =
    try
      let Seqrule (r, c) = make_seq_rule (List.rev toks) in
      Arules [Rules (r, apply c [])]
    with SelfSymbol ->
      CErrors.user_err (str "Recursive symbols (self / next) are not allowed in local rules")
  in
  Tac2entries.ScopeRule (scope, (fun e -> e))
end
