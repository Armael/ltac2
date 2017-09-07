(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Pp
open Genarg
open Names
open Tac2expr
open Tac2env

(** Utils *)

let change_kn_label kn id =
  let (mp, dp, _) = KerName.repr kn in
  KerName.make mp dp (Label.of_id id)

let paren p = hov 2 (str "(" ++ p ++ str ")")

(** Type printing *)

type typ_level =
| T5_l
| T5_r
| T2
| T1
| T0

let t_unit =
  KerName.make2 Tac2env.coq_prefix (Label.of_id (Id.of_string "unit"))

let pr_typref kn =
  Libnames.pr_qualid (Tac2env.shortest_qualid_of_type kn)

let pr_glbtype_gen pr lvl c =
  let rec pr_glbtype lvl = function
  | GTypVar n -> str "'" ++ str (pr n)
  | GTypRef (Other kn, []) -> pr_typref kn
  | GTypRef (Other kn, [t]) ->
    let paren = match lvl with
    | T5_r | T5_l | T2 | T1 -> fun x -> x
    | T0 -> paren
    in
    paren (pr_glbtype lvl t ++ spc () ++ pr_typref kn)
  | GTypRef (Other kn, tl) ->
    let paren = match lvl with
    | T5_r | T5_l | T2 | T1 -> fun x -> x
    | T0 -> paren
    in
    paren (str "(" ++ prlist_with_sep (fun () -> str ", ") (pr_glbtype lvl) tl ++ str ")" ++ spc () ++ pr_typref kn)
  | GTypArrow (t1, t2) ->
    let paren = match lvl with
    | T5_r -> fun x -> x
    | T5_l | T2 | T1 | T0 -> paren
    in
    paren (pr_glbtype T5_l t1 ++ spc () ++ str "->" ++ spc () ++ pr_glbtype T5_r t2)
  | GTypRef (Tuple 0, []) ->
    Libnames.pr_qualid (Tac2env.shortest_qualid_of_type t_unit)
  | GTypRef (Tuple _, tl) ->
    let paren = match lvl with
    | T5_r | T5_l -> fun x -> x
    | T2 | T1 | T0 -> paren
    in
    paren (prlist_with_sep (fun () -> str " * ") (pr_glbtype T2) tl)
  in
  hov 0 (pr_glbtype lvl c)

let pr_glbtype pr c = pr_glbtype_gen pr T5_r c

let int_name () =
  let vars = ref Int.Map.empty in
  fun n ->
    if Int.Map.mem n !vars then Int.Map.find n !vars
    else
      let num = Int.Map.cardinal !vars in
      let base = num mod 26 in
      let rem = num / 26 in
      let name = String.make 1 (Char.chr (97 + base)) in
      let suff = if Int.equal rem 0 then "" else string_of_int rem in
      let name = name ^ suff in
      let () = vars := Int.Map.add n name !vars in
      name

(** Term printing *)

let pr_constructor kn =
  Libnames.pr_qualid (Tac2env.shortest_qualid_of_constructor kn)

let pr_projection kn =
  Libnames.pr_qualid (Tac2env.shortest_qualid_of_projection kn)

type exp_level = Tac2expr.exp_level =
| E5
| E4
| E3
| E2
| E1
| E0

let pr_atom = function
| AtmInt n -> int n
| AtmStr s -> qstring s

let pr_name = function
| Name id -> Id.print id
| Anonymous -> str "_"

let find_constructor n empty def =
  let rec find n = function
  | [] -> assert false
  | (id, []) as ans :: rem ->
    if empty then
      if Int.equal n 0 then ans
      else find (pred n) rem
    else find n rem
  | (id, _ :: _) as ans :: rem ->
    if not empty then
      if Int.equal n 0 then ans
      else find (pred n) rem
    else find n rem
  in
  find n def

let pr_internal_constructor tpe n is_const =
  let data = match Tac2env.interp_type tpe with
  | (_, GTydAlg data) -> data
  | _ -> assert false
  in
  let (id, _) = find_constructor n is_const data.galg_constructors in
  let kn = change_kn_label tpe id in
  pr_constructor kn

let order_branches cbr nbr def =
  let rec order cidx nidx def = match def with
  | [] -> []
  | (id, []) :: rem ->
    let ans = order (succ cidx) nidx rem in
    (id, [], cbr.(cidx)) :: ans
  | (id, _ :: _) :: rem ->
    let ans = order cidx (succ nidx) rem in
    let (vars, e) = nbr.(nidx) in
    (id, Array.to_list vars, e) :: ans
  in
  order 0 0 def

let pr_glbexpr_gen lvl c =
  let rec pr_glbexpr lvl = function
  | GTacAtm atm -> pr_atom atm
  | GTacVar id -> Id.print id
  | GTacRef gr ->
    let qid = shortest_qualid_of_ltac (TacConstant gr) in
    Libnames.pr_qualid qid
  | GTacFun (nas, c) ->
    let nas = pr_sequence pr_name nas in
    let paren = match lvl with
    | E0 | E1 | E2 | E3 | E4 -> paren
    | E5 -> fun x -> x
    in
    paren (hov 0 (hov 2 (str "fun" ++ spc () ++ nas) ++ spc () ++ str "=>" ++ spc () ++
      pr_glbexpr E5 c))
  | GTacApp (c, cl) ->
    let paren = match lvl with
    | E0 -> paren
    | E1 | E2 | E3 | E4 | E5 -> fun x -> x
    in
    paren (hov 2 (pr_glbexpr E1 c ++ spc () ++ (pr_sequence (pr_glbexpr E0) cl)))
  | GTacLet (mut, bnd, e) ->
    let paren = match lvl with
    | E0 | E1 | E2 | E3 | E4 -> paren
    | E5 -> fun x -> x
    in
    let mut = if mut then str "rec" ++ spc () else mt () in
    let pr_bnd (na, e) =
      pr_name na ++ spc () ++ str ":=" ++ spc () ++ hov 2 (pr_glbexpr E5 e) ++ spc ()
    in
    let bnd = prlist_with_sep (fun () -> str "with" ++ spc ()) pr_bnd bnd in
    paren (hv 0 (hov 2 (str "let" ++ spc () ++ mut ++ bnd ++ str "in") ++ spc () ++ pr_glbexpr E5 e))
  | GTacCst (Tuple 0, _, _) -> str "()"
  | GTacCst (Tuple _, _, cl) ->
    let paren = match lvl with
    | E0 | E1 -> paren
    | E2 | E3 | E4 | E5 -> fun x -> x
    in
    paren (prlist_with_sep (fun () -> str "," ++ spc ()) (pr_glbexpr E1) cl)
  | GTacCst (Other tpe, n, cl) ->
    begin match Tac2env.interp_type tpe with
    | _, GTydAlg def ->
      let paren = match lvl with
      | E0 -> paren
      | E1 | E2 | E3 | E4 | E5 -> fun x -> x
      in
      let cstr = pr_internal_constructor tpe n (List.is_empty cl) in
      let cl = match cl with
      | [] -> mt ()
      | _ -> spc () ++ pr_sequence (pr_glbexpr E0) cl
      in
      paren (hov 2 (cstr ++ cl))
    | _, GTydRec def ->
      let args = List.combine def cl in
      let pr_arg ((id, _, _), arg) =
        let kn = change_kn_label tpe id in
        pr_projection kn ++ spc () ++ str ":=" ++ spc () ++ pr_glbexpr E1 arg
      in
      let args = prlist_with_sep (fun () -> str ";" ++ spc ()) pr_arg args in
      hv 0 (str "{" ++ spc () ++ args ++ spc () ++ str "}")
    | _, (GTydDef _ | GTydOpn) -> assert false
    end
  | GTacCse (e, info, cst_br, ncst_br) ->
    let e = pr_glbexpr E5 e in
    let br = match info with
    | Other kn ->
      let def = match Tac2env.interp_type kn with
      | _, GTydAlg { galg_constructors = def } -> def
      | _, GTydDef _ | _, GTydRec _ | _, GTydOpn -> assert false
      in
      let br = order_branches cst_br ncst_br def in
      let pr_branch (cstr, vars, p) =
        let cstr = change_kn_label kn cstr in
        let cstr = pr_constructor cstr in
        let vars = match vars with
        | [] -> mt ()
        | _ -> spc () ++ pr_sequence pr_name vars
        in
        hov 4 (str "|" ++ spc () ++ hov 0 (cstr ++ vars ++ spc () ++ str "=>") ++ spc () ++
          hov 2 (pr_glbexpr E5 p)) ++ spc ()
      in
      prlist pr_branch br
    | Tuple n ->
      let (vars, p) = if Int.equal n 0 then ([||], cst_br.(0)) else ncst_br.(0) in
      let p = pr_glbexpr E5 p in
      let vars = prvect_with_sep (fun () -> str "," ++ spc ()) pr_name vars in
      hov 4 (str "|" ++ spc () ++ hov 0 (paren vars ++ spc () ++ str "=>") ++ spc () ++ p)
    in
    v 0 (hv 0 (str "match" ++ spc () ++ e ++ spc () ++ str "with") ++ spc () ++ br ++ spc () ++ str "end")
  | GTacWth wth ->
    let e = pr_glbexpr E5 wth.opn_match in
    let pr_pattern c self vars p =
      let self = match self with
      | Anonymous -> mt ()
      | Name id -> spc () ++ str "as" ++ spc () ++ Id.print id
      in
      hov 4 (str "|" ++ spc () ++ hov 0 (c ++ vars ++ self ++ spc () ++ str "=>") ++ spc () ++
        hov 2 (pr_glbexpr E5 p)) ++ spc ()
    in
    let pr_branch (cstr, (self, vars, p)) =
      let cstr = pr_constructor cstr in
      let vars = match Array.to_list vars with
      | [] -> mt ()
      | vars -> spc () ++ pr_sequence pr_name vars
      in
      pr_pattern cstr self vars p
    in
    let br = prlist pr_branch (KNmap.bindings wth.opn_branch) in
    let (def_as, def_p) = wth.opn_default in
    let def = pr_pattern (str "_") def_as (mt ()) def_p in
    let br = br ++ def in
    v 0 (hv 0 (str "match" ++ spc () ++ e ++ spc () ++ str "with") ++ spc () ++ br ++ str "end")
  | GTacPrj (kn, e, n) ->
    let def = match Tac2env.interp_type kn with
    | _, GTydRec def -> def
    | _, GTydDef _ | _, GTydAlg _ | _, GTydOpn -> assert false
    in
    let (proj, _, _) = List.nth def n in
    let proj = change_kn_label kn proj in
    let proj = pr_projection proj in
    let e = pr_glbexpr E0 e in
    hov 0 (e ++ str "." ++ paren proj)
  | GTacSet (kn, e, n, r) ->
    let def = match Tac2env.interp_type kn with
    | _, GTydRec def -> def
    | _, GTydDef _ | _, GTydAlg _ | _, GTydOpn -> assert false
    in
    let (proj, _, _) = List.nth def n in
    let proj = change_kn_label kn proj in
    let proj = pr_projection proj in
    let e = pr_glbexpr E0 e in
    let r = pr_glbexpr E1 r in
    hov 0 (e ++ str "." ++ paren proj ++ spc () ++ str ":=" ++ spc () ++ r)
  | GTacOpn (kn, cl) ->
    let paren = match lvl with
    | E0 -> paren
    | E1 | E2 | E3 | E4 | E5 -> fun x -> x
    in
    let c = pr_constructor kn in
    paren (hov 0 (c ++ spc () ++ (pr_sequence (pr_glbexpr E0) cl)))
  | GTacExt (tag, arg) ->
    let tpe = interp_ml_object tag in
    hov 0 (tpe.ml_print (Global.env ()) arg) (** FIXME *)
  | GTacPrm (prm, args) ->
    let args = match args with
    | [] -> mt ()
    | _ -> spc () ++ pr_sequence (pr_glbexpr E0) args
    in
    hov 0 (str "@external" ++ spc () ++ qstring prm.mltac_plugin ++ spc () ++
      qstring prm.mltac_tactic ++ args)
  in
  hov 0 (pr_glbexpr lvl c)

let pr_glbexpr c =
  pr_glbexpr_gen E5 c

(** Toplevel printers *)

let rec subst_type subst (t : 'a glb_typexpr) = match t with
| GTypVar id -> subst.(id)
| GTypArrow (t1, t2) -> GTypArrow (subst_type subst t1, subst_type subst t2)
| GTypRef (qid, args) ->
  GTypRef (qid, List.map (fun t -> subst_type subst t) args)

let unfold kn args =
  let (nparams, def) = Tac2env.interp_type kn in
  match def with
  | GTydDef (Some def) ->
    let args = Array.of_list args in
    Some (subst_type args def)
  | _ -> None

let rec kind t = match t with
| GTypVar id -> GTypVar id
| GTypRef (Other kn, tl) ->
  begin match unfold kn tl with
  | None -> t
  | Some t -> kind t
  end
| GTypArrow _ | GTypRef (Tuple _, _) -> t

type val_printer =
  { val_printer : 'a. Environ.env -> Evd.evar_map -> valexpr -> 'a glb_typexpr list -> Pp.t }

let printers = ref KNmap.empty

let register_val_printer kn pr =
  printers := KNmap.add kn pr !printers

open Tac2ffi

let rec pr_valexpr env sigma v t = match kind t with
| GTypVar _ -> str "<poly>"
| GTypRef (Other kn, params) ->
  let pr = try Some (KNmap.find kn !printers) with Not_found -> None in
  begin match pr with
  | Some pr -> pr.val_printer env sigma v params
  | None ->
    let n, repr = Tac2env.interp_type kn in
    match repr with
    | GTydDef None -> str "<abstr>"
    | GTydDef (Some _) ->
      (** Shouldn't happen thanks to kind *)
      assert false
    | GTydAlg alg ->
      begin match v with
      | ValInt n -> pr_internal_constructor kn n true
      | ValBlk (n, args) ->
        let (id, tpe) = find_constructor n false alg.galg_constructors in
        let knc = change_kn_label kn id in
        let args = pr_constrargs env sigma params args tpe in
        hv 2 (pr_constructor knc ++ spc () ++ str "(" ++ args ++ str ")")
      | _ -> str "<unknown>"
      end
    | GTydRec rcd -> str "{}"
    | GTydOpn ->
      begin match v with
      | ValOpn (knc, [||]) -> pr_constructor knc
      | ValOpn (knc, args) ->
        let data = Tac2env.interp_constructor knc in
        let args = pr_constrargs env sigma params args data.Tac2env.cdata_args in
        hv 2 (pr_constructor knc ++ spc () ++ str "(" ++ args ++ str ")")
      | _ -> str "<unknown>"
      end
  end
| GTypArrow _ -> str "<fun>"
| GTypRef (Tuple _, tl) ->
  let blk = Array.to_list (block.r_to v) in
  if List.length blk == List.length tl then
    let prs = List.map2 (fun v t -> pr_valexpr env sigma v t) blk tl in
    hv 2 (str "(" ++ prlist_with_sep pr_comma (fun p -> p) prs ++ str ")")
  else
    str "<unknown>"

and pr_constrargs env sigma params args tpe =
  let subst = Array.of_list params in
  let tpe = List.map (fun t -> subst_type subst t) tpe in
  let args = Array.to_list args in
  let args = List.combine args tpe in
  prlist_with_sep pr_comma (fun (v, t) -> pr_valexpr env sigma v t) args

let register_init n f =
  let kn = KerName.make2 Tac2env.coq_prefix (Label.make n) in
  register_val_printer kn { val_printer = fun _ _ v _ -> f v }

let () = register_init "int" begin fun n ->
  let n = to_int n in
  Pp.int n
end

let () = register_init "string" begin fun s ->
  let s = to_string s in
  Pp.quote (Pp.str s)
end

let () = register_init "ident" begin fun id ->
  let id = to_ident id in
  Pp.str "@" ++ Id.print id
end

let () = register_init "message" begin fun pp ->
  str "message:(" ++ to_pp pp ++ str ")"
end

let () = register_init "err" begin fun e ->
  let (e, _) = to_ext val_exn e in
  str "err:(" ++ CErrors.print_no_report e ++ str ")"
end
