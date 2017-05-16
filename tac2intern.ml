(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Pp
open Util
open Genarg
open CErrors
open Names
open Libnames
open Misctypes
open Tac2env
open Tac2print
open Tac2expr

(** Hardwired types and constants *)

let coq_type n = KerName.make2 Tac2env.coq_prefix (Label.make n)

let t_int = coq_type "int"
let t_string = coq_type "string"
let t_array = coq_type "array"
let t_unit = coq_type "unit"
let t_list = coq_type "list"

let c_nil = GTacCst (GCaseAlg t_list, 0, [])
let c_cons e el = GTacCst (GCaseAlg t_list, 0, [e; el])

(** Union find *)

module UF :
sig
type elt
type 'a t
val equal : elt -> elt -> bool
val create : unit -> 'a t
val fresh : 'a t -> elt
val find : elt -> 'a t -> (elt * 'a option)
val union : elt -> elt -> 'a t -> unit
val set : elt -> 'a -> 'a t -> unit
module Map :
sig
  type key = elt
  type +'a t
  val empty : 'a t
  val add : key -> 'a -> 'a t -> 'a t
  val mem : key -> 'a t -> bool
  val find : key -> 'a t -> 'a
  val exists : (key -> 'a -> bool) -> 'a t -> bool
end
end
=
struct
type elt = int
let equal = Int.equal
module Map = Int.Map

type 'a node =
| Canon of int * 'a option
| Equiv of elt

type 'a t = {
  mutable uf_data : 'a node array;
  mutable uf_size : int;
}

let resize p =
  if Int.equal (Array.length p.uf_data) p.uf_size then begin
    let nsize = 2 * p.uf_size + 1 in
    let v = Array.make nsize (Equiv 0) in
    Array.blit p.uf_data 0 v 0 (Array.length p.uf_data);
    p.uf_data <- v;
  end

let create () = { uf_data = [||]; uf_size = 0 }

let fresh p =
  resize p;
  let n = p.uf_size in
  p.uf_data.(n) <- (Canon (1, None));
  p.uf_size <- n + 1;
  n

let rec lookup n p =
  let node = Array.get p.uf_data n in
  match node with
  | Canon (size, v) -> n, size, v
  | Equiv y ->
    let ((z, _, _) as res) = lookup y p in
    if not (Int.equal z y) then Array.set p.uf_data n (Equiv z);
    res

let find n p =
  let (x, _, v) = lookup n p in (x, v)

let union x y p =
  let ((x, size1, _) as xcan) = lookup x p in
  let ((y, size2, _) as ycan) = lookup y p in
  let xcan, ycan = if size1 < size2 then xcan, ycan else ycan, xcan in
  let x, _, xnode = xcan in
  let y, _, ynode = ycan in
  assert (Option.is_empty xnode);
  assert (Option.is_empty ynode);
  p.uf_data.(x) <- Equiv y;
  p.uf_data.(y) <- Canon (size1 + size2, None)

let set x v p =
  let (x, s, v') = lookup x p in
  assert (Option.is_empty v');
  p.uf_data.(x) <- Canon (s, Some v)

end

type mix_var =
| GVar of UF.elt
| LVar of int

type mix_type_scheme = int * mix_var glb_typexpr

type environment = {
  env_var : mix_type_scheme Id.Map.t;
  (** Type schemes of bound variables *)
  env_cst : UF.elt glb_typexpr UF.t;
  (** Unification state *)
  env_als : UF.elt Id.Map.t ref;
  (** Map user-facing type variables to unification variables *)
  env_opn : bool;
  (** Accept unbound type variables *)
  env_rec : (KerName.t * int) Id.Map.t;
  (** Recursive type definitions *)
}

let empty_env () = {
  env_var = Id.Map.empty;
  env_cst = UF.create ();
  env_als = ref Id.Map.empty;
  env_opn = true;
  env_rec = Id.Map.empty;
}

let env_name env =
  (** Generate names according to a provided environment *)
  let mk num =
    let base = num mod 26 in
    let rem = num / 26 in
    let name = String.make 1 (Char.chr (97 + base)) in
    let suff = if Int.equal rem 0 then "" else string_of_int rem in
    let name = name ^ suff in
    name
  in
  let fold id elt acc = UF.Map.add elt (Id.to_string id) acc in
  let vars = Id.Map.fold fold env.env_als.contents UF.Map.empty in
  let vars = ref vars in
  let rec fresh n =
    let name = mk n in
    if UF.Map.exists (fun _ name' -> String.equal name name') !vars then fresh (succ n)
    else name
  in
  fun n ->
    if UF.Map.mem n !vars then UF.Map.find n !vars
    else
      let ans = fresh 0 in
      let () = vars := UF.Map.add n ans !vars in
      ans

let ltac2_env : environment Genintern.Store.field =
  Genintern.Store.field ()

let fresh_id env = UF.fresh env.env_cst

let get_alias (loc, id) env =
  try Id.Map.find id env.env_als.contents
  with Not_found ->
    if env.env_opn then
      let n = fresh_id env in
      let () = env.env_als := Id.Map.add id n env.env_als.contents in
      n
    else user_err ~loc (str "Unbound type parameter " ++ Id.print id)

let push_name id t env = match id with
| Anonymous -> env
| Name id -> { env with env_var = Id.Map.add id t env.env_var }

let loc_of_tacexpr = function
| CTacAtm (loc, _) -> loc
| CTacRef (RelId (loc, _)) -> loc
| CTacRef (AbsKn _) -> Loc.ghost
| CTacFun (loc, _, _) -> loc
| CTacApp (loc, _, _) -> loc
| CTacLet (loc, _, _, _) -> loc
| CTacTup (loc, _) -> loc
| CTacArr (loc, _) -> loc
| CTacLst (loc, _) -> loc
| CTacCnv (loc, _, _) -> loc
| CTacSeq (loc, _, _) -> loc
| CTacCse (loc, _, _) -> loc
| CTacRec (loc, _) -> loc
| CTacPrj (loc, _, _) -> loc
| CTacSet (loc, _, _, _) -> loc
| CTacExt (loc, _) -> loc

let loc_of_patexpr = function
| CPatAny loc -> loc
| CPatRef (loc, _, _) -> loc
| CPatTup (loc, _) -> loc

let error_nargs_mismatch loc nargs nfound =
  user_err ~loc (str "Constructor expects " ++ int nargs ++
    str " arguments, but is applied to " ++ int nfound ++
    str " arguments")

let error_nparams_mismatch loc nargs nfound =
  user_err ~loc (str "Type expects " ++ int nargs ++
    str " arguments, but is applied to " ++ int nfound ++
    str " arguments")

let rec subst_type subst (t : 'a glb_typexpr) = match t with
| GTypVar id -> subst id
| GTypArrow (t1, t2) -> GTypArrow (subst_type subst t1, subst_type subst t2)
| GTypTuple tl -> GTypTuple (List.map (fun t -> subst_type subst t) tl)
| GTypRef (qid, args) ->
  GTypRef (qid, List.map (fun t -> subst_type subst t) args)

let rec intern_type env (t : raw_typexpr) : UF.elt glb_typexpr = match t with
| CTypVar (loc, Name id) -> GTypVar (get_alias (loc, id) env)
| CTypVar (_, Anonymous) -> GTypVar (fresh_id env)
| CTypRef (loc, rel, args) ->
  let (kn, nparams) = match rel with
  | RelId (loc, qid) ->
    let (dp, id) = repr_qualid qid in
    if DirPath.is_empty dp && Id.Map.mem id env.env_rec then
      Id.Map.find id env.env_rec
    else
      let kn =
        try Tac2env.locate_type qid
        with Not_found ->
          user_err ~loc (str "Unbound type constructor " ++ pr_qualid qid)
      in
      let (nparams, _) = Tac2env.interp_type kn in
      (kn, nparams)
  | AbsKn kn ->
    let (nparams, _) = Tac2env.interp_type kn in
    (kn, nparams)
  in
  let nargs = List.length args in
  let () =
    if not (Int.equal nparams nargs) then
      let loc, qid = match rel with
      | RelId lid -> lid
      | AbsKn kn -> loc, shortest_qualid_of_type kn
      in
      user_err ~loc (strbrk "The type constructor " ++ pr_qualid qid ++
        strbrk " expects " ++ int nparams ++ strbrk " argument(s), but is here \
        applied to " ++ int nargs ++ strbrk "argument(s)")
  in
  GTypRef (kn, List.map (fun t -> intern_type env t) args)
| CTypArrow (loc, t1, t2) -> GTypArrow (intern_type env t1, intern_type env t2)
| CTypTuple (loc, tl) -> GTypTuple (List.map (fun t -> intern_type env t) tl)

let fresh_type_scheme env (t : type_scheme) : UF.elt glb_typexpr =
  let (n, t) = t in
  let subst = Array.init n (fun _ -> fresh_id env) in
  let substf i = GTypVar subst.(i) in
  subst_type substf t

let fresh_mix_type_scheme env (t : mix_type_scheme) : UF.elt glb_typexpr =
  let (n, t) = t in
  let subst = Array.init n (fun _ -> fresh_id env) in
  let substf = function
  | LVar i -> GTypVar subst.(i)
  | GVar n -> GTypVar n
  in
  subst_type substf t

let fresh_reftype env (kn : KerName.t) =
  let (n, _) = Tac2env.interp_type kn in
  let subst = Array.init n (fun _ -> fresh_id env) in
  let t = GTypRef (kn, Array.map_to_list (fun i -> GTypVar i) subst) in
  (subst, t)

(** First-order unification algorithm *)

let is_unfoldable kn = match snd (Tac2env.interp_type kn) with
| GTydDef (Some _) -> true
| GTydDef None | GTydAlg _ | GTydRec _ | GTydOpn -> false

let unfold env kn args =
  let (nparams, def) = Tac2env.interp_type kn in
  let def = match def with
  | GTydDef (Some t) -> t
  | _ -> assert false
  in
  let args = Array.of_list args in
  let subst n = args.(n) in
  subst_type subst def

(** View function, allows to ensure head normal forms *)
let rec kind env t = match t with
| GTypVar id ->
  let (id, v) = UF.find id env.env_cst in
  begin match v with
  | None -> GTypVar id
  | Some t -> kind env t
  end
| GTypRef (kn, tl) ->
  if is_unfoldable kn then kind env (unfold env kn tl) else t
| GTypArrow _ | GTypTuple _ -> t

exception Occur

let rec occur_check env id t = match kind env t with
| GTypVar id' -> if UF.equal id id' then raise Occur
| GTypArrow (t1, t2) ->
  let () = occur_check env id t1 in
  occur_check env id t2
| GTypTuple tl ->
  List.iter (fun t -> occur_check env id t) tl
| GTypRef (kn, tl) ->
  List.iter (fun t -> occur_check env id t) tl

exception CannotUnify of UF.elt glb_typexpr * UF.elt glb_typexpr

let unify_var env id t = match kind env t with
| GTypVar id' ->
  if not (UF.equal id id') then UF.union id id' env.env_cst
| GTypArrow _ | GTypRef _ | GTypTuple _ ->
  try
    let () = occur_check env id t in
    UF.set id t env.env_cst
  with Occur -> raise (CannotUnify (GTypVar id, t))

let rec unify env t1 t2 = match kind env t1, kind env t2 with
| GTypVar id, t | t, GTypVar id ->
  unify_var env id t
| GTypArrow (t1, u1), GTypArrow (t2, u2) ->
  let () = unify env t1 t2 in
  unify env u1 u2
| GTypTuple tl1, GTypTuple tl2 ->
  if Int.equal (List.length tl1) (List.length tl2) then
    List.iter2 (fun t1 t2 -> unify env t1 t2) tl1 tl2
  else raise (CannotUnify (t1, t2))
| GTypRef (kn1, tl1), GTypRef (kn2, tl2) ->
  if KerName.equal kn1 kn2 then
    List.iter2 (fun t1 t2 -> unify env t1 t2) tl1 tl2
  else raise (CannotUnify (t1, t2))
| _ -> raise (CannotUnify (t1, t2))

let unify loc env t1 t2 =
  try unify env t1 t2
  with CannotUnify (u1, u2) ->
    let name = env_name env in
    user_err ~loc (str "This expression has type " ++ pr_glbtype name t1 ++
      str " but an expression what expected of type " ++ pr_glbtype name t2)

(** Term typing *)

let is_pure_constructor kn =
  match snd (Tac2env.interp_type kn) with
  | GTydAlg _ | GTydOpn -> true
  | GTydRec fields ->
    let is_pure (_, mut, _) = not mut in
    List.for_all is_pure fields
  | GTydDef _ -> assert false (** Type definitions have no constructors *)

let rec is_value = function
| GTacAtm (AtmInt _) | GTacVar _ | GTacRef _ | GTacFun _ -> true
| GTacAtm (AtmStr _) | GTacApp _ | GTacLet _ -> false
| GTacCst (GCaseTuple _, _, el) -> List.for_all is_value el
| GTacCst (_, _, []) -> true
| GTacOpn (_, el) -> List.for_all is_value el
| GTacCst (GCaseAlg kn, _, el) -> is_pure_constructor kn && List.for_all is_value el
| GTacArr _ | GTacCse _ | GTacPrj _ | GTacSet _ | GTacExt _ | GTacPrm _
| GTacWth _ -> false

let is_rec_rhs = function
| GTacFun _ -> true
| GTacAtm _ | GTacVar _ | GTacRef _ | GTacApp _ | GTacLet _ | GTacPrj _
| GTacSet _ | GTacArr _ | GTacExt _ | GTacPrm _ | GTacCst _
| GTacCse _ | GTacOpn _ | GTacWth _ -> false

let rec fv_type f t accu = match t with
| GTypVar id -> f id accu
| GTypArrow (t1, t2) -> fv_type f t1 (fv_type f t2 accu)
| GTypTuple tl -> List.fold_left (fun accu t -> fv_type f t accu) accu tl
| GTypRef (kn, tl) -> List.fold_left (fun accu t -> fv_type f t accu) accu tl

let fv_env env =
  let rec f id accu = match UF.find id env.env_cst with
  | id, None -> UF.Map.add id () accu
  | _, Some t -> fv_type f t accu
  in
  let fold_var id (_, t) accu =
    let fmix id accu = match id with
    | LVar _ -> accu
    | GVar id -> f id accu
    in
    fv_type fmix t accu
  in
  let fv_var = Id.Map.fold fold_var env.env_var UF.Map.empty in
  let fold_als _ id accu = f id accu in
  Id.Map.fold fold_als !(env.env_als) fv_var

let abstract_var env (t : UF.elt glb_typexpr) : mix_type_scheme =
  let fv = fv_env env in
  let count = ref 0 in
  let vars = ref UF.Map.empty in
  let rec subst id =
    let (id, t) = UF.find id env.env_cst in
    match t with
    | None ->
      if UF.Map.mem id fv then GTypVar (GVar id)
      else
        begin try UF.Map.find id !vars
        with Not_found ->
          let n = !count in
          let var = GTypVar (LVar n) in
          let () = incr count in
          let () = vars := UF.Map.add id var !vars in
          var
        end
    | Some t -> subst_type subst t
  in
  let t = subst_type subst t in
  (!count, t)

let monomorphic (t : UF.elt glb_typexpr) : mix_type_scheme =
  let subst id = GTypVar (GVar id) in
  (0, subst_type subst t)

let warn_not_unit =
  CWarnings.create ~name:"not-unit" ~category:"ltac"
    (fun () -> strbrk "The following expression should have type unit.")

let warn_redundant_clause =
  CWarnings.create ~name:"redundant-clause" ~category:"ltac"
    (fun () -> strbrk "The following clause is redundant.")

let check_elt_unit loc env t =
  let maybe_unit = match kind env t with
  | GTypVar _ -> true
  | GTypArrow _ | GTypTuple _ -> false
  | GTypRef (kn, _) -> KerName.equal kn t_unit
  in
  if not maybe_unit then warn_not_unit ~loc ()

let check_elt_empty loc env t = match kind env t with
| GTypVar _ ->
  user_err ~loc (str "Cannot infer an empty type for this expression")
| GTypArrow _ | GTypTuple _ ->
  let name = env_name env in
  user_err ~loc (str "Type " ++ pr_glbtype name t ++ str " is not an empty type")
| GTypRef (kn, _) ->
  let def = Tac2env.interp_type kn in
  match def with
  | _, GTydAlg [] -> kn
  | _ ->
    let name = env_name env in
    user_err ~loc (str "Type " ++ pr_glbtype name t ++ str " is not an empty type")

let check_unit ?loc t =
  let maybe_unit = match t with
  | GTypVar _ -> true
  | GTypArrow _ | GTypTuple _ -> false
  | GTypRef (kn, _) -> KerName.equal kn t_unit
  in
  if not maybe_unit then warn_not_unit ?loc ()

let check_redundant_clause = function
| [] -> ()
| (p, _) :: _ -> warn_redundant_clause ~loc:(loc_of_patexpr p) ()

let get_variable0 mem var = match var with
| RelId (loc, qid) ->
  let (dp, id) = repr_qualid qid in
  if DirPath.is_empty dp && mem id then ArgVar (loc, id)
  else
    let kn =
      try Tac2env.locate_ltac qid
      with Not_found ->
        CErrors.user_err ~loc (str "Unbound value " ++ pr_qualid qid)
    in
    ArgArg kn
| AbsKn kn -> ArgArg kn

let get_variable env var =
  let mem id = Id.Map.mem id env.env_var in
  get_variable0 mem var

let get_constructor env var = match var with
| RelId (loc, qid) ->
  let c = try Some (Tac2env.locate_ltac qid) with Not_found -> None in
  begin match c with
  | Some (TacConstructor knc) ->
    let kn = Tac2env.interp_constructor knc in
    ArgArg (kn, knc)
  | Some (TacConstant _) ->
    CErrors.user_err ~loc (str "The term " ++ pr_qualid qid ++
      str " is not the constructor of an inductive type.")
  | None ->
    let (dp, id) = repr_qualid qid in
    if DirPath.is_empty dp then ArgVar (loc, id)
    else CErrors.user_err ~loc (str "Unbound constructor " ++ pr_qualid qid)
  end
| AbsKn knc ->
  let kn = Tac2env.interp_constructor knc in
  ArgArg (kn, knc)

let get_projection var = match var with
| RelId (loc, qid) ->
  let kn = try Tac2env.locate_projection qid with Not_found ->
    user_err ~loc (pr_qualid qid ++ str " is not a projection")
  in
  Tac2env.interp_projection kn
| AbsKn kn ->
  Tac2env.interp_projection kn

let intern_atm env = function
| AtmInt n -> (GTacAtm (AtmInt n), GTypRef (t_int, []))
| AtmStr s -> (GTacAtm (AtmStr s), GTypRef (t_string, []))

let invalid_pattern ~loc kn t =
  let pt = match t with
  | GCaseAlg kn' -> pr_typref kn
  | GCaseTuple n -> str "tuple"
  in
  user_err ~loc (str "Invalid pattern, expected a pattern for type " ++
    pr_typref kn ++ str ", found a pattern of type " ++ pt) (** FIXME *)

(** Pattern view *)

type glb_patexpr =
| GPatVar of Name.t
| GPatRef of ltac_constructor * glb_patexpr list
| GPatTup of glb_patexpr list

let rec intern_patexpr env = function
| CPatAny _ -> GPatVar Anonymous
| CPatRef (_, qid, []) ->
  begin match get_constructor env qid with
  | ArgVar (_, id) -> GPatVar (Name id)
  | ArgArg (_, kn) -> GPatRef (kn, [])
  end
| CPatRef (_, qid, pl) ->
  begin match get_constructor env qid with
  | ArgVar (loc, id) ->
    user_err ~loc (str "Unbound constructor " ++ Nameops.pr_id id)
  | ArgArg (_, kn) -> GPatRef (kn, List.map (fun p -> intern_patexpr env p) pl)
  end
| CPatTup (_, pl) ->
  GPatTup (List.map (fun p -> intern_patexpr env p) pl)

type pattern_kind =
| PKind_empty
| PKind_variant of type_constant
| PKind_open of type_constant
| PKind_tuple of int
| PKind_any

let get_pattern_kind env pl = match pl with
| [] -> PKind_empty
| p :: pl ->
  let rec get_kind (p, _) pl = match intern_patexpr env p with
  | GPatVar _ ->
    begin match pl with
    | [] -> PKind_any
    | p :: pl -> get_kind p pl
    end
  | GPatRef (kn, pl) ->
    let data = Tac2env.interp_constructor kn in
    if Option.is_empty data.cdata_indx then PKind_open data.cdata_type
    else PKind_variant data.cdata_type
  | GPatTup tp -> PKind_tuple (List.length tp)
  in
  get_kind p pl

(** Internalization *)

let is_constructor env qid = match get_variable env qid with
| ArgArg (TacConstructor _) -> true
| _ -> false

let rec intern_rec env = function
| CTacAtm (_, atm) -> intern_atm env atm
| CTacRef qid as e ->
  begin match get_variable env qid with
  | ArgVar (_, id) ->
    let sch = Id.Map.find id env.env_var in
    (GTacVar id, fresh_mix_type_scheme env sch)
  | ArgArg (TacConstant kn) ->
    let (_, _, sch) = Tac2env.interp_global kn in
    (GTacRef kn, fresh_type_scheme env sch)
  | ArgArg (TacConstructor kn) ->
    let loc = loc_of_tacexpr e in
    intern_constructor env loc kn []
  end
| CTacFun (loc, bnd, e) ->
  let fold (env, bnd, tl) ((_, na), t) =
    let t = match t with
    | None -> GTypVar (fresh_id env)
    | Some t -> intern_type env t
    in
    let env = push_name na (monomorphic t) env in
    (env, na :: bnd, t :: tl)
  in
  let (env, bnd, tl) = List.fold_left fold (env, [], []) bnd in
  let bnd = List.rev bnd in
  let (e, t) = intern_rec env e in
  let t = List.fold_left (fun accu t -> GTypArrow (t, accu)) t tl in
  (GTacFun (bnd, e), t)
| CTacApp (loc, CTacRef qid, args) as e when is_constructor env qid ->
  let kn = match get_variable env qid with
  | ArgArg (TacConstructor kn) -> kn
  | _ -> assert false
  in
  let loc = loc_of_tacexpr e in
  intern_constructor env loc kn args
| CTacApp (loc, f, args) ->
  let (f, ft) = intern_rec env f in
  let fold arg (args, t) =
    let (arg, argt) = intern_rec env arg in
    (arg :: args, GTypArrow (argt, t))
  in
  let ret = GTypVar (fresh_id env) in
  let (args, t) = List.fold_right fold args ([], ret) in
  let () = unify loc env ft t in
  (GTacApp (f, args), ret)
| CTacLet (loc, false, el, e) ->
  let fold accu ((loc, na), _, _) = match na with
  | Anonymous -> accu
  | Name id ->
    if Id.Set.mem id accu then
      user_err ~loc (str "Variable " ++ Id.print id ++ str " is bound several \
        times in this matching")
    else Id.Set.add id accu
  in
  let _ = List.fold_left fold Id.Set.empty el in
  let fold ((loc, na), tc, e) (el, p) =
    let (e, t) = intern_rec env e in
    let () = match tc with
    | None -> ()
    | Some tc ->
      let tc = intern_type env tc in
      unify loc env t tc
    in
    let t = if is_value e then abstract_var env t else monomorphic t in
    ((na, e) :: el), ((na, t) :: p)
  in
  let (el, p) = List.fold_right fold el ([], []) in
  let nenv = List.fold_left (fun accu (na, t) -> push_name na t env) env p in
  let (e, t) = intern_rec nenv e in
  (GTacLet (false, el, e), t)
| CTacLet (loc, true, el, e) ->
  intern_let_rec env loc el e
| CTacTup (loc, []) ->
  (GTacCst (GCaseAlg t_unit, 0, []), GTypRef (t_unit, []))
| CTacTup (loc, el) ->
  let fold e (el, tl) =
    let (e, t) = intern_rec env e in
    (e :: el, t :: tl)
  in
  let (el, tl) = List.fold_right fold el ([], []) in
  (GTacCst (GCaseTuple (List.length el), 0, el), GTypTuple tl)
| CTacArr (loc, []) ->
  let id = fresh_id env in
  (GTacArr [], GTypRef (t_int, [GTypVar id]))
| CTacArr (loc, e0 :: el) ->
  let (e0, t0) = intern_rec env e0 in
  let fold e el = intern_rec_with_constraint env e t0 :: el in
  let el = e0 :: List.fold_right fold el [] in
  (GTacArr el, GTypRef (t_array, [t0]))
| CTacLst (loc, []) ->
  let id = fresh_id env in
  (c_nil, GTypRef (t_list, [GTypVar id]))
| CTacLst (loc, e0 :: el) ->
  let (e0, t0) = intern_rec env e0 in
  let fold e el = c_cons (intern_rec_with_constraint env e t0) el in
  let el = c_cons e0 (List.fold_right fold el c_nil) in
  (el, GTypRef (t_list, [t0]))
| CTacCnv (loc, e, tc) ->
  let (e, t) = intern_rec env e in
  let tc = intern_type env tc in
  let () = unify loc env t tc in
  (e, tc)
| CTacSeq (loc, e1, e2) ->
  let (e1, t1) = intern_rec env e1 in
  let (e2, t2) = intern_rec env e2 in
  let () = check_elt_unit loc env t1 in
  (GTacLet (false, [Anonymous, e1], e2), t2)
| CTacCse (loc, e, pl) ->
  intern_case env loc e pl
| CTacRec (loc, fs) ->
  intern_record env loc fs
| CTacPrj (loc, e, proj) ->
  let pinfo = get_projection proj in
  let loc = loc_of_tacexpr e in
  let (e, t) = intern_rec env e in
  let subst = Array.init pinfo.pdata_prms (fun _ -> fresh_id env) in
  let params = Array.map_to_list (fun i -> GTypVar i) subst in
  let exp = GTypRef (pinfo.pdata_type, params) in
  let () = unify loc env t exp in
  let substf i = GTypVar subst.(i) in
  let ret = subst_type substf pinfo.pdata_ptyp in
  (GTacPrj (pinfo.pdata_type, e, pinfo.pdata_indx), ret)
| CTacSet (loc, e, proj, r) ->
  let pinfo = get_projection proj in
  let () =
    if not pinfo.pdata_mutb then
      let loc = match proj with
      | RelId (loc, _) -> loc
      | AbsKn _ -> Loc.ghost
      in
      user_err ~loc (str "Field is not mutable")
  in
  let subst = Array.init pinfo.pdata_prms (fun _ -> fresh_id env) in
  let params = Array.map_to_list (fun i -> GTypVar i) subst in
  let exp = GTypRef (pinfo.pdata_type, params) in
  let e = intern_rec_with_constraint env e exp in
  let substf i = GTypVar subst.(i) in
  let ret = subst_type substf pinfo.pdata_ptyp in
  let r = intern_rec_with_constraint env r ret in
  (GTacSet (pinfo.pdata_type, e, pinfo.pdata_indx, r), GTypRef (t_unit, []))
| CTacExt (loc, ext) ->
  let open Genintern in
  let GenArg (Rawwit tag, _) = ext in
  let tpe = interp_ml_object tag in
  (** External objects do not have access to the named context because this is
      not stable by dynamic semantics. *)
  let genv = Global.env_of_context Environ.empty_named_context_val in
  let ist = empty_glob_sign genv in
  let ist = { ist with extra = Store.set ist.extra ltac2_env env } in
  let (_, ext) = Flags.with_option Ltac_plugin.Tacintern.strict_check (fun () -> generic_intern ist ext) () in
  (GTacExt ext, GTypRef (tpe.ml_type, []))

and intern_rec_with_constraint env e exp =
  let loc = loc_of_tacexpr e in
  let (e, t) = intern_rec env e in
  let () = unify loc env t exp in
  e

and intern_let_rec env loc el e =
  let fold accu ((loc, na), _, _) = match na with
  | Anonymous -> accu
  | Name id ->
    if Id.Set.mem id accu then
      user_err ~loc (str "Variable " ++ Id.print id ++ str " is bound several \
        times in this matching")
    else Id.Set.add id accu
  in
  let _ = List.fold_left fold Id.Set.empty el in
  let map env ((loc, na), t, e) =
    let id = fresh_id env in
    let env = push_name na (monomorphic (GTypVar id)) env in
    (env, (loc, na, t, e, id))
  in
  let (env, el) = List.fold_map map env el in
  let fold (loc, na, tc, e, id) (el, tl) =
    let loc_e = loc_of_tacexpr e in
    let (e, t) = intern_rec env e in
    let () =
      if not (is_rec_rhs e) then
        user_err ~loc:loc_e (str "This kind of expression is not allowed as \
          right-hand side of a recursive binding")
    in
    let () = unify loc env t (GTypVar id) in
    let () = match tc with
    | None -> ()
    | Some tc ->
      let tc = intern_type env tc in
      unify loc env t tc
    in
    ((na, e) :: el, t :: tl)
  in
  let (el, tl) = List.fold_right fold el ([], []) in
  let (e, t) = intern_rec env e in
  (GTacLet (true, el, e), t)

(** For now, patterns recognized by the pattern-matching compiling are limited
    to depth-one where leaves are either variables or catch-all *)
and intern_case env loc e pl =
  let (e', t) = intern_rec env e in
  let todo ~loc () = user_err ~loc (str "Pattern not handled yet") in
  match get_pattern_kind env pl with
  | PKind_any ->
    let (pat, b) = List.hd pl in
    let na = match intern_patexpr env pat with
    | GPatVar na -> na
    | _ -> assert false
    in
    let () = check_redundant_clause (List.tl pl) in
    let env = push_name na (monomorphic t) env in
    let (b, tb) = intern_rec env b in
    (GTacLet (false, [na, e'], b), tb)
  | PKind_empty ->
    let kn = check_elt_empty loc env t in
    let r = fresh_id env in
    (GTacCse (e', GCaseAlg kn, [||], [||]), GTypVar r)
  | PKind_tuple len ->
    begin match pl with
    | [] -> assert false
    | [CPatTup (_, []), b] ->
      let () = unify (loc_of_tacexpr e) env t (GTypRef (t_unit, [])) in
      let (b, tb) = intern_rec env b in
      (GTacCse (e', GCaseAlg t_unit, [|b|], [||]), tb)
    | [CPatTup (_, pl), b] ->
      let map = function
      | CPatAny _ -> Anonymous
      | CPatRef (loc, qid, []) ->
        begin match get_constructor env qid with
        | ArgVar (_, id) -> Name id
        | ArgArg _ -> todo ~loc ()
        end
      | p -> todo ~loc:(loc_of_patexpr p) ()
      in
      let ids = Array.map_of_list map pl in
      let tc = GTypTuple (List.map (fun _ -> GTypVar (fresh_id env)) pl) in
      let () = unify (loc_of_tacexpr e) env t tc in
      let (b, tb) = intern_rec env b in
      (GTacCse (e', GCaseTuple len, [||], [|ids, b|]), tb)
    | (p, _) :: _ -> todo ~loc:(loc_of_patexpr p) ()
    end
  | PKind_variant kn ->
    let subst, tc = fresh_reftype env kn in
    let () = unify (loc_of_tacexpr e) env t tc in
    let (params, def) = Tac2env.interp_type kn in
    let cstrs = match def with
    | GTydAlg c -> c
    | _ -> assert false
    in
    let count (const, nonconst) (c, args) = match args with
    | [] -> (succ const, nonconst)
    | _ :: _ -> (const, succ nonconst)
    in
    let nconst, nnonconst = List.fold_left count (0, 0) cstrs in
    let const = Array.make nconst None in
    let nonconst = Array.make nnonconst None in
    let ret = GTypVar (fresh_id env) in
    let rec intern_branch = function
    | [] -> ()
    | (pat, br) :: rem ->
      let tbr = match pat with
      | CPatAny _ ->
        let () = check_redundant_clause rem in
        let (br', brT) = intern_rec env br in
        (** Fill all remaining branches *)
        let fill (ncst, narg) (_, args) =
          if List.is_empty args then
            let () =
              if Option.is_empty const.(ncst) then const.(ncst) <- Some br'
            in
            (succ ncst, narg)
          else
            let () =
              if Option.is_empty const.(narg) then
                let ids = Array.map_of_list (fun _ -> Anonymous) args in
                nonconst.(narg) <- Some (ids, br')
            in
            (ncst, succ narg)
        in
        let _ = List.fold_left fill (0, 0) cstrs in
        brT
      | CPatRef (loc, qid, args) ->
        let data = match get_constructor env qid with
        | ArgVar _ -> todo ~loc ()
        | ArgArg (data, _) ->
          let () =
            let kn' = data.cdata_type in
            if not (KerName.equal kn kn') then
              invalid_pattern ~loc kn (GCaseAlg kn')
          in
          data
        in
        let get_id = function
        | CPatAny _ -> Anonymous
        | CPatRef (loc, qid, []) ->
          begin match get_constructor env qid with
          | ArgVar (_, id) -> Name id
          | ArgArg _ -> todo ~loc ()
          end
        | p -> todo ~loc:(loc_of_patexpr p) ()
        in
        let ids = List.map get_id args in
        let nids = List.length ids in
        let nargs = List.length data.cdata_args in
        let () =
          if not (Int.equal nids nargs) then error_nargs_mismatch loc nargs nids
        in
        let fold env id tpe =
          (** Instantiate all arguments *)
          let subst n = GTypVar subst.(n) in
          let tpe = subst_type subst tpe in
          push_name id (monomorphic tpe) env
        in
        let nenv = List.fold_left2 fold env ids data.cdata_args in
        let (br', brT) = intern_rec nenv br in
        let () =
          let index = match data.cdata_indx with
          | Some i -> i
          | None -> assert false
          in
          if List.is_empty args then
            if Option.is_empty const.(index) then const.(index) <- Some br'
            else warn_redundant_clause ~loc ()
          else
            let ids = Array.of_list ids in
            if Option.is_empty nonconst.(index) then nonconst.(index) <- Some (ids, br')
            else warn_redundant_clause ~loc ()
        in
        brT
      | CPatTup (loc, tup) ->
        invalid_pattern ~loc kn (GCaseTuple (List.length tup))
      in
      let () = unify (loc_of_tacexpr br) env ret tbr in
      intern_branch rem
    in
    let () = intern_branch pl in
    let map = function
    | None -> user_err ~loc (str "TODO: Unhandled match case") (** FIXME *)
    | Some x -> x
    in
    let const = Array.map map const in
    let nonconst = Array.map map nonconst in
    let ce = GTacCse (e', GCaseAlg kn, const, nonconst) in
    (ce, ret)
  | PKind_open kn ->
    let subst, tc = fresh_reftype env kn in
    let () = unify (loc_of_tacexpr e) env t tc in
    let ret = GTypVar (fresh_id env) in
    let rec intern_branch map = function
    | [] ->
      user_err ~loc (str "Missing default case")
    | (pat, br) :: rem ->
      match intern_patexpr env pat with
      | GPatVar na ->
        let () = check_redundant_clause rem in
        let nenv = push_name na (monomorphic tc) env in
        let br' = intern_rec_with_constraint nenv br ret in
        let def = (na, br') in
        (map, def)
      | GPatRef (knc, args) ->
        let get = function
        | GPatVar na -> na
        | GPatRef _ | GPatTup _ ->
          user_err ~loc (str "TODO: Unhandled match case") (** FIXME *)
        in
        let loc = loc_of_patexpr pat in
        let ids = List.map get args in
        let data = Tac2env.interp_constructor knc in
        let () =
          if not (KerName.equal kn data.cdata_type) then
            invalid_pattern ~loc kn (GCaseAlg data.cdata_type)
        in
        let nids = List.length ids in
        let nargs = List.length data.cdata_args in
        let () =
          if not (Int.equal nids nargs) then error_nargs_mismatch loc nargs nids
        in
        let fold env id tpe =
          (** Instantiate all arguments *)
          let subst n = GTypVar subst.(n) in
          let tpe = subst_type subst tpe in
          push_name id (monomorphic tpe) env
        in
        let nenv = List.fold_left2 fold env ids data.cdata_args in
        let br' = intern_rec_with_constraint nenv br ret in
        let map =
          if KNmap.mem knc map then
            let () = warn_redundant_clause ~loc () in
            map
          else
            KNmap.add knc (Anonymous, Array.of_list ids, br') map
        in
        intern_branch map rem
      | GPatTup tup ->
        invalid_pattern ~loc kn (GCaseTuple (List.length tup))
    in
    let (map, def) = intern_branch KNmap.empty pl in
    (GTacWth { opn_match = e'; opn_branch = map; opn_default = def }, ret)

and intern_constructor env loc kn args =
  let cstr = interp_constructor kn in
  let nargs = List.length cstr.cdata_args in
  if Int.equal nargs (List.length args) then
    let subst = Array.init cstr.cdata_prms (fun _ -> fresh_id env) in
    let substf i = GTypVar subst.(i) in
    let types = List.map (fun t -> subst_type substf t) cstr.cdata_args in
    let ans = GTypRef (cstr.cdata_type, List.init cstr.cdata_prms (fun i -> GTypVar subst.(i))) in
    let map arg tpe = intern_rec_with_constraint env arg tpe in
    let args = List.map2 map args types in
    match cstr.cdata_indx with
    | Some idx ->
      (GTacCst (GCaseAlg cstr.cdata_type, idx, args), ans)
    | None ->
      (GTacOpn (kn, args), ans)
  else
    error_nargs_mismatch loc nargs (List.length args)

and intern_record env loc fs =
  let map (proj, e) =
    let loc = match proj with
    | RelId (loc, _) -> loc
    | AbsKn _ -> Loc.ghost
    in
    let proj = get_projection proj in
    (loc, proj, e)
  in
  let fs = List.map map fs in
  let kn = match fs with
  | [] -> user_err ~loc (str "Cannot infer the corresponding record type")
  | (_, proj, _) :: _ -> proj.pdata_type
  in
  let params, typdef = match Tac2env.interp_type kn with
  | n, GTydRec def -> n, def
  | _ -> assert false
  in
  let subst = Array.init params (fun _ -> fresh_id env) in
  (** Set the answer [args] imperatively *)
  let args = Array.make (List.length typdef) None in
  let iter (loc, pinfo, e) =
    if KerName.equal kn pinfo.pdata_type then
      let index = pinfo.pdata_indx in
      match args.(index) with
      | None ->
        let exp = subst_type (fun i -> GTypVar subst.(i)) pinfo.pdata_ptyp in
        let e = intern_rec_with_constraint env e exp in
        args.(index) <- Some e
      | Some _ ->
        let (name, _, _) = List.nth typdef pinfo.pdata_indx in
        user_err ~loc (str "Field " ++ Id.print name ++ str " is defined \
          several times")
    else
      user_err ~loc (str "Field " ++ (*KerName.print knp ++*) str " does not \
        pertain to record definition " ++ pr_typref pinfo.pdata_type)
  in
  let () = List.iter iter fs in
  let () = match Array.findi (fun _ o -> Option.is_empty o) args with
  | None -> ()
  | Some i ->
    let (field, _, _) = List.nth typdef i in
    user_err ~loc (str "Field " ++ Id.print field ++ str " is undefined")
  in
  let args = Array.map_to_list Option.get args in
  let tparam = List.init params (fun i -> GTypVar subst.(i)) in
  (GTacCst (GCaseAlg kn, 0, args), GTypRef (kn, tparam))

let normalize env (count, vars) (t : UF.elt glb_typexpr) =
  let get_var id =
    try UF.Map.find id !vars
    with Not_found ->
      let () = assert env.env_opn in
      let n = GTypVar !count in
      let () = incr count in
      let () = vars := UF.Map.add id n !vars in
      n
  in
  let rec subst id = match UF.find id env.env_cst with
  | id, None -> get_var id
  | _, Some t -> subst_type subst t
  in
  subst_type subst t

let intern e =
  let env = empty_env () in
  let (e, t) = intern_rec env e in
  let count = ref 0 in
  let vars = ref UF.Map.empty in
  let t = normalize env (count, vars) t in
  (e, (!count, t))

let intern_typedef self (ids, t) : glb_quant_typedef =
  let env = { (empty_env ()) with env_rec = self } in
  (** Initialize type parameters *)
  let map id = get_alias id env in
  let ids = List.map map ids in
  let count = ref (List.length ids) in
  let vars = ref UF.Map.empty in
  let iter n id = vars := UF.Map.add id (GTypVar n) !vars in
  let () = List.iteri iter ids in
  (** Do not accept unbound type variables *)
  let env = { env with env_opn = false } in
  let intern t =
    let t = intern_type env t in
    normalize env (count, vars) t
  in
  let count = !count in
  match t with
  | CTydDef None -> (count, GTydDef None)
  | CTydDef (Some t) -> (count, GTydDef (Some (intern t)))
  | CTydAlg constrs ->
    let map (c, t) = (c, List.map intern t) in
    let constrs = List.map map constrs in
    (count, GTydAlg constrs)
  | CTydRec fields ->
    let map (c, mut, t) = (c, mut, intern t) in
    let fields = List.map map fields in
    (count, GTydRec fields)
  | CTydOpn -> (count, GTydOpn)

let intern_open_type t =
  let env = empty_env () in
  let t = intern_type env t in
  let count = ref 0 in
  let vars = ref UF.Map.empty in
  let t = normalize env (count, vars) t in
  (!count, t)

(** Globalization *)

let add_name accu = function
| Name id -> Id.Set.add id accu
| Anonymous -> accu

let get_projection0 var = match var with
| RelId (loc, qid) ->
  let kn = try Tac2env.locate_projection qid with Not_found ->
    user_err ~loc (pr_qualid qid ++ str " is not a projection")
  in
  kn
| AbsKn kn -> kn

let rec globalize ids e = match e with
| CTacAtm _ -> e
| CTacRef ref ->
  let mem id = Id.Set.mem id ids in
  begin match get_variable0 mem ref with
  | ArgVar _ -> e
  | ArgArg kn -> CTacRef (AbsKn kn)
  end
| CTacFun (loc, bnd, e) ->
  let fold accu ((_, na), _) = add_name accu na in
  let ids = List.fold_left fold ids bnd in
  let e = globalize ids e in
  CTacFun (loc, bnd, e)
| CTacApp (loc, e, el) ->
  let e = globalize ids e in
  let el = List.map (fun e -> globalize ids e) el in
  CTacApp (loc, e, el)
| CTacLet (loc, isrec, bnd, e) ->
  let fold accu ((_, na), _, _) = add_name accu na in
  let ext = List.fold_left fold Id.Set.empty bnd in
  let eids = Id.Set.union ext ids in
  let e = globalize eids e in
  let map (qid, t, e) =
    let ids = if isrec then eids else ids in
    (qid, t, globalize ids e)
  in
  let bnd = List.map map bnd in
  CTacLet (loc, isrec, bnd, e)
| CTacTup (loc, el) ->
  let el = List.map (fun e -> globalize ids e) el in
  CTacTup (loc, el)
| CTacArr (loc, el) ->
  let el = List.map (fun e -> globalize ids e) el in
  CTacArr (loc, el)
| CTacLst (loc, el) ->
  let el = List.map (fun e -> globalize ids e) el in
  CTacLst (loc, el)
| CTacCnv (loc, e, t) ->
  let e = globalize ids e in
  CTacCnv (loc, e, t)
| CTacSeq (loc, e1, e2) ->
  let e1 = globalize ids e1 in
  let e2 = globalize ids e2 in
  CTacSeq (loc, e1, e2)
| CTacCse (loc, e, bl) ->
  let e = globalize ids e in
  let bl = List.map (fun b -> globalize_case ids b) bl in
  CTacCse (loc, e, bl)
| CTacRec (loc, r) ->
  let map (p, e) =
    let p = get_projection0 p in
    let e = globalize ids e in
    (AbsKn p, e)
  in
  CTacRec (loc, List.map map r)
| CTacPrj (loc, e, p) ->
  let e = globalize ids e in
  let p = get_projection0 p in
  CTacPrj (loc, e, AbsKn p)
| CTacSet (loc, e, p, e') ->
  let e = globalize ids e in
  let p = get_projection0 p in
  let e' = globalize ids e' in
  CTacSet (loc, e, AbsKn p, e')
| CTacExt (loc, arg) ->
  let arg = pr_argument_type (genarg_tag arg) in
  CErrors.user_err ~loc (str "Cannot globalize generic arguments of type" ++ spc () ++ arg)

and globalize_case ids (p, e) =
  (globalize_pattern ids p, globalize ids e)

and globalize_pattern ids p = match p with
| CPatAny _ -> p
| CPatRef (loc, cst, pl) ->
  let cst = match get_constructor () cst with
  | ArgVar _ -> cst
  | ArgArg (_, knc) -> AbsKn knc
  in
  let pl = List.map (fun p -> globalize_pattern ids p) pl in
  CPatRef (loc, cst, pl)
| CPatTup (loc, pl) ->
  let pl = List.map (fun p -> globalize_pattern ids p) pl in
  CPatTup (loc, pl)

(** Kernel substitution *)

open Mod_subst

let rec subst_type subst t = match t with
| GTypVar _ -> t
| GTypArrow (t1, t2) ->
  let t1' = subst_type subst t1 in
  let t2' = subst_type subst t2 in
  if t1' == t1 && t2' == t2 then t
  else GTypArrow (t1', t2')
| GTypTuple tl ->
  let tl'= List.smartmap (fun t -> subst_type subst t) tl in
  if tl' == tl then t else GTypTuple tl'
| GTypRef (kn, tl) ->
  let kn' = subst_kn subst kn in
  let tl' = List.smartmap (fun t -> subst_type subst t) tl in
  if kn' == kn && tl' == tl then t else GTypRef (kn', tl')

let subst_case_info subst ci = match ci with
| GCaseAlg kn ->
  let kn' = subst_kn subst kn in
  if kn' == kn then ci else GCaseAlg kn'
| GCaseTuple _ -> ci

let rec subst_expr subst e = match e with
| GTacAtm _ | GTacVar _ | GTacPrm _ -> e
| GTacRef kn -> GTacRef (subst_kn subst kn)
| GTacFun (ids, e) -> GTacFun (ids, subst_expr subst e)
| GTacApp (f, args) ->
  GTacApp (subst_expr subst f, List.map (fun e -> subst_expr subst e) args)
| GTacLet (r, bs, e) ->
  let bs = List.map (fun (na, e) -> (na, subst_expr subst e)) bs in
  GTacLet (r, bs, subst_expr subst e)
| GTacArr el ->
  GTacArr (List.map (fun e -> subst_expr subst e) el)
| GTacCst (t, n, el) as e0 ->
  let t' = match t with
  | GCaseAlg kn ->
    let kn' = subst_kn subst kn in
    if kn' == kn then t else GCaseAlg kn'
  | GCaseTuple _ -> t
  in
  let el' = List.smartmap (fun e -> subst_expr subst e) el in
  if t' == t && el' == el then e0 else GTacCst (t', n, el')
| GTacCse (e, ci, cse0, cse1) ->
  let cse0' = Array.map (fun e -> subst_expr subst e) cse0 in
  let cse1' = Array.map (fun (ids, e) -> (ids, subst_expr subst e)) cse1 in
  let ci' = subst_case_info subst ci in
  GTacCse (subst_expr subst e, ci', cse0', cse1')
| GTacWth { opn_match = e; opn_branch = br; opn_default = (na, def) } as e0 ->
  let e' = subst_expr subst e in
  let def' = subst_expr subst def in
  let fold kn (self, vars, p) accu =
    let kn' = subst_kn subst kn in
    let p' = subst_expr subst p in
    if kn' == kn && p' == p then accu
    else KNmap.add kn' (self, vars, p') (KNmap.remove kn accu)
  in
  let br' = KNmap.fold fold br br in
  if e' == e && br' == br && def' == def then e0
  else GTacWth { opn_match = e'; opn_default = (na, def'); opn_branch = br' }
| GTacPrj (kn, e, p) as e0 ->
  let kn' = subst_kn subst kn in
  let e' = subst_expr subst e in
  if kn' == kn && e' == e then e0 else GTacPrj (kn', e', p)
| GTacSet (kn, e, p, r) as e0 ->
  let kn' = subst_kn subst kn in
  let e' = subst_expr subst e in
  let r' = subst_expr subst r in
  if kn' == kn && e' == e && r' == r then e0 else GTacSet (kn', e', p, r')
| GTacExt ext ->
  let ext' = Genintern.generic_substitute subst ext in
  if ext' == ext then e else GTacExt ext'
| GTacOpn (kn, el) as e0 ->
  let kn' = subst_kn subst kn in
  let el' = List.smartmap (fun e -> subst_expr subst e) el in
  if kn' == kn && el' == el then e0 else GTacOpn (kn', el')

let subst_typedef subst e = match e with
| GTydDef t ->
  let t' = Option.smartmap (fun t -> subst_type subst t) t in
  if t' == t then e else GTydDef t'
| GTydAlg constrs ->
  let map (c, tl as p) =
    let tl' = List.smartmap (fun t -> subst_type subst t) tl in
    if tl' == tl then p else (c, tl')
  in
  let constrs' = List.smartmap map constrs in
  if constrs' == constrs then e else GTydAlg constrs'
| GTydRec fields ->
  let map (c, mut, t as p) =
    let t' = subst_type subst t in
    if t' == t then p else (c, mut, t')
  in
  let fields' = List.smartmap map fields in
  if fields' == fields then e else GTydRec fields'
| GTydOpn -> GTydOpn

let subst_quant_typedef subst (prm, def as qdef) =
  let def' = subst_typedef subst def in
  if def' == def then qdef else (prm, def')

let subst_type_scheme subst (prm, t as sch) =
  let t' = subst_type subst t in
  if t' == t then sch else (prm, t')

let subst_or_relid subst ref = match ref with
| RelId _ -> ref
| AbsKn kn ->
  let kn' = subst_kn subst kn in
  if kn' == kn then ref else AbsKn kn'

let rec subst_rawtype subst t = match t with
| CTypVar _ -> t
| CTypArrow (loc, t1, t2) ->
  let t1' = subst_rawtype subst t1 in
  let t2' = subst_rawtype subst t2 in
  if t1' == t1 && t2' == t2 then t else CTypArrow (loc, t1', t2')
| CTypTuple (loc, tl) ->
  let tl' = List.smartmap (fun t -> subst_rawtype subst t) tl in
  if tl' == tl then t else CTypTuple (loc, tl')
| CTypRef (loc, ref, tl) ->
  let ref' = subst_or_relid subst ref in
  let tl' = List.smartmap (fun t -> subst_rawtype subst t) tl in
  if ref' == ref && tl' == tl then t else CTypRef (loc, ref', tl')

let subst_tacref subst ref = match ref with
| RelId _ -> ref
| AbsKn (TacConstant kn) ->
  let kn' = subst_kn subst kn in
  if kn' == kn then ref else AbsKn (TacConstant kn')
| AbsKn (TacConstructor kn) ->
  let kn' = subst_kn subst kn in
  if kn' == kn then ref else AbsKn (TacConstructor kn')

let subst_projection subst prj = match prj with
| RelId _ -> prj
| AbsKn kn ->
  let kn' = subst_kn subst kn in
  if kn' == kn then prj else AbsKn kn'

let rec subst_rawpattern subst p = match p with
| CPatAny _ -> p
| CPatRef (loc, c, pl) ->
  let pl' = List.smartmap (fun p -> subst_rawpattern subst p) pl in
  let c' = match c with
  | RelId _ -> c
  | AbsKn kn ->
    let kn' = subst_kn subst kn in
    if kn' == kn then c else AbsKn kn'
  in
  if pl' == pl && c' == c then p else CPatRef (loc, c', pl')
| CPatTup (loc, pl) ->
  let pl' = List.smartmap (fun p -> subst_rawpattern subst p) pl in
  if pl' == pl then p else CPatTup (loc, pl')

(** Used for notations *)
let rec subst_rawexpr subst t = match t with
| CTacAtm _ -> t
| CTacRef ref ->
  let ref' = subst_tacref subst ref in
  if ref' == ref then t else CTacRef ref'
| CTacFun (loc, bnd, e) ->
  let map (na, t as p) =
    let t' = Option.smartmap (fun t -> subst_rawtype subst t) t in
    if t' == t then p else (na, t')
  in
  let bnd' = List.smartmap map bnd in
  let e' = subst_rawexpr subst e in
  if bnd' == bnd && e' == e then t else CTacFun (loc, bnd', e')
| CTacApp (loc, e, el) ->
  let e' = subst_rawexpr subst e in
  let el' = List.smartmap (fun e -> subst_rawexpr subst e) el in
  if e' == e && el' == el then t else CTacApp (loc, e', el')
| CTacLet (loc, isrec, bnd, e) ->
  let map (na, t, e as p) =
    let t' = Option.smartmap (fun t -> subst_rawtype subst t) t in
    let e' = subst_rawexpr subst e in
    if t' == t && e' == e then p else (na, t', e')
  in
  let bnd' = List.smartmap map bnd in
  let e' = subst_rawexpr subst e in
  if bnd' == bnd && e' == e then t else CTacLet (loc, isrec, bnd', e')
| CTacTup (loc, el) ->
  let el' = List.smartmap (fun e -> subst_rawexpr subst e) el in
  if el' == el then t else CTacTup (loc, el')
| CTacArr (loc, el) ->
  let el' = List.smartmap (fun e -> subst_rawexpr subst e) el in
  if el' == el then t else CTacArr (loc, el')
| CTacLst (loc, el) ->
  let el' = List.smartmap (fun e -> subst_rawexpr subst e) el in
  if el' == el then t else CTacLst (loc, el')
| CTacCnv (loc, e, c) ->
  let e' = subst_rawexpr subst e in
  let c' = subst_rawtype subst c in
  if c' == c && e' == e then t else CTacCnv (loc, e', c')
| CTacSeq (loc, e1, e2) ->
  let e1' = subst_rawexpr subst e1 in
  let e2' = subst_rawexpr subst e2 in
  if e1' == e1 && e2' == e2 then t else CTacSeq (loc, e1', e2')
| CTacCse (loc, e, bl) ->
  let map (p, e as x) =
    let p' = subst_rawpattern subst p in
    let e' = subst_rawexpr subst e in
    if p' == p && e' == e then x else (p', e')
  in
  let e' = subst_rawexpr subst e in
  let bl' = List.smartmap map bl in
  if e' == e && bl' == bl then t else CTacCse (loc, e', bl')
| CTacRec (loc, el) ->
  let map (prj, e as p) =
    let prj' = subst_projection subst prj in
    let e' = subst_rawexpr subst e in
    if prj' == prj && e' == e then p else (prj', e')
  in
  let el' = List.smartmap map el in
  if el' == el then t else CTacRec (loc, el')
| CTacPrj (loc, e, prj) ->
    let prj' = subst_projection subst prj in
    let e' = subst_rawexpr subst e in
    if prj' == prj && e' == e then t else CTacPrj (loc, e', prj')
| CTacSet (loc, e, prj, r) ->
    let prj' = subst_projection subst prj in
    let e' = subst_rawexpr subst e in
    let r' = subst_rawexpr subst r in
    if prj' == prj && e' == e && r' == r then t else CTacSet (loc, e', prj', r')
| CTacExt _ -> assert false (** Should not be generated by gloabalization *)

(** Registering *)

let () =
  let open Genintern in
  let intern ist tac =
    let env = match Genintern.Store.get ist.extra ltac2_env with
    | None -> empty_env ()
    | Some env -> env
    in
    let loc = loc_of_tacexpr tac in
    let (tac, t) = intern_rec env tac in
    let () = check_elt_unit loc env t in
    (ist, tac)
  in
  Genintern.register_intern0 wit_ltac2 intern
let () = Genintern.register_subst0 wit_ltac2 subst_expr