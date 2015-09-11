(*
 * Copyright (c) 2015 Gabriel Radanne <drupyog@zoho.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Graph
open Functoria_misc
module Dsl = Functoria_dsl
module Key = Functoria_key

(** {2 Utility} *)

let fold_lefti f l z =
  fst @@ List.fold_left (fun (s,i) x -> f i x s, i+1) (z,0) l

(** Check if [l] is an increasing sequence from [O] to [len-1]. *)
let is_sequence l =
  snd @@
  List.fold_left
    (fun (i,b) (j,_) -> i+1, b && (i = j))
    (0,true)
    l

(** {2 Graph} *)

type subconf = <
  name: string ;
  module_name: string ;
  keys: Key.t list ;
  packages: string list Key.value ;
  libraries: string list Key.value ;
  connect : Dsl.Info.t -> string -> string list -> string ;
  configure: Dsl.Info.t -> unit ;
  clean: Dsl.Info.t -> unit ;
>

type description =
  | If of bool Key.value
  | Impl of subconf
  | App

type label =
  | Parameter of int
  | Dependency of int
  | Condition of [`Else | `Then]



module V_ = struct
  type t = description
end

module E_ = struct
  type t = label
  let default = Parameter 0
  let compare = compare
end

module G = Persistent.Digraph.AbstractLabeled (V_) (E_)

type t = G.t
type vertex = G.V.t

module Dfs = Traverse.Dfs(G)
module Topo = Topological.Make(G)

(** Graph utilities *)

let add_edge e1 label e2 graph =
  G.add_edge_e graph @@ G.E.create e1 label e2

let for_all_vertex f g =
  G.fold_vertex (fun v b -> b && f v) g true

(** Remove a vertex and all its orphan successors, recursively. *)
let rec remove_recursively g v =
  let children = G.succ g v in
  let g = G.remove_vertex g v in
  List.fold_right
    (fun c g ->
       if G.in_degree g c = 0
       then remove_recursively g c
       else g)
    children
    g

(** [add_pred_with_subst g preds v] add the edges [pred] to [g]
    with the destination replaced by [v]. *)
let add_pred_with_subst g preds v =
  List.fold_left
    (fun g e -> G.add_edge_e g @@ G.E.(create (src e) (label e) v))
    g
    preds

(** [add_succs_with_subst g succs v ~sub ~by] add the edges [succs] to [g]
    with the source replaced by [v].
    If a destination is [sub] it is replaced by [by]. *)
let add_succ_with_subst g succs v ~sub ~by =
  List.fold_left
    (fun g e ->
       let dest = G.E.dst e in
       let dest = if G.V.equal dest sub then by else dest in
       G.add_edge_e g @@ G.E.(create v (label e) dest))
    g
    succs


(** {2 Graph construction} *)

let add_impl graph ~impl ~args ~deps =
  let v = G.V.create (Impl impl) in
  v,
  graph
  |> fold_lefti (fun i -> add_edge v (Parameter i)) args
  |> fold_lefti (fun i -> add_edge v (Dependency i)) deps

let add_if graph ~cond ~else_ ~then_ =
  let v = G.V.create (If cond) in
  v,
  graph
  |> add_edge v (Condition `Else) else_
  |> add_edge v (Condition `Then) then_

let add_app graph ~f ~x =
  let v = G.V.create App in
  v,
  graph
  |> add_edge v (Parameter 0) f
  |> add_edge v (Parameter 1) x

let create impl =
  let rec aux
    : type t . G.t -> t Dsl.impl -> G.vertex * G.t
    = fun g -> function
    | Dsl.Impl c ->
      let deps, g =
        List.fold_right
          (fun (Dsl.Any x) (l,g) -> let v, g = aux g x in v::l, g)
          c#dependencies ([], g)
      in
      add_impl g ~impl:(c :> subconf) ~args:[] ~deps
    | Dsl.If (cond, then_, else_) ->
      let then_, g = aux g then_ in
      let else_, g = aux g else_ in
      add_if g ~cond ~then_ ~else_
    | Dsl.App {f; x} ->
      let f, g = aux g f in
      let x, g = aux g x in
      add_app g ~f ~x
  in
  snd @@ aux G.empty impl

let is_impl v = match G.V.label v with
  | Impl _ -> true
  | _ -> false

let is_if v = match G.V.label v with
  | If _ -> true
  | _ -> false

(** {2 Invariant checking} *)
(** The invariants are the following:
    - [If] nodes have exactly 2 children,
      one [Condition `Else] and one [Condition `Then]
    - [Impl] nodes have [n] [Parameter] children and [m] [Dependency] children.
      [Parameter] (resp. [Dependency]) children are labeled
      from [0] to [n-1] (resp. [m-1]).
      They do not have [Condition] children.
    - [App] nodes have [n] [Parameter] children, with [n >= 2].
      They are labeled similarly to [Impl] node's children.
      They have neither [Condition] nor [dependency] children.
    - There are no cycles.
    - There is only one root (node with a degree 1). There are no orphans.
*)

let get_children g v =
  let split l =
    List.fold_right
      (fun e (args, deps, conds) -> match G.E.label e with
         | Parameter i -> (i, G.E.dst e)::args, deps, conds
         | Dependency i -> args, (i, G.E.dst e)::deps, conds
         | Condition side -> args, deps, (side, G.E.dst e)::conds)
      l
      ([],[],[])
  in
  let args, deps, cond = split @@ G.succ_e g v in
  let args = List.sort (fun (i,_) (j,_) -> compare i j) args in
  let deps = List.sort (fun (i,_) (j,_) -> compare i j) deps in
  let cond = match cond with
    | [`Else, else_ ; `Then, then_]
    | [`Then, then_; `Else, else_] -> Some (then_, else_)
    | [] -> None
    | _ -> assert false
  in
  assert (is_sequence args) ;
  assert (is_sequence deps) ;
  `Args (List.map snd args), `Deps (List.map snd deps), cond

let explode g v = match G.V.label v, get_children g v with
  | Impl i, (args, deps, None) -> `Impl (i, args, deps)
  | If cond, (`Args [], `Deps [], Some (then_, else_)) ->
    `If (cond, then_, else_)
  | App, (`Args (f::args), `Deps [], None) -> `App (f, args)
  | _ -> assert false

let iter g f =
  if Dfs.has_cycle g then
    invalid_arg "Functoria_graph.iter: A graph should not have cycles." ;
  Topo.iter f g

(** {2 Graph destruction} *)

let collect
  : type ty. (module Monoid with type t = ty) ->
    (description -> ty) -> G.t -> ty
  = fun (module M) f g ->
    let open M in
    G.fold_vertex (fun v s -> f (G.V.label v) ++ s) g empty

(** {2 Graph manipulation} *)

(** Find a pattern in a graph. *)
exception Found
let find g predicate =
  let r = ref None in
  try
    G.iter_vertex
      (fun v -> match predicate g v with
         | Some _ as x -> r := x ; raise Found
         | None -> ())
      g ; None
  with Found -> !r

(** Find a pattern and apply the transformation, repeatedly. *)
(* This could probably be made more efficient, but it would be complicated. *)
let rec transform ~predicate ~apply g =
  match find g predicate with
  | Some v_if ->
    transform ~predicate ~apply @@ apply g v_if
  | None -> g


module PushIf = struct
  (** Push [If] nodes the further "up" possible.

      If [n] is [Impl] or [App], [m = If cond] and [m ∈ succ n] then
      we replace the couple (n,m) by the triple (m', n₀, n₁) where
      - [m' = If cond] with children [n₀] and [n₁]
      - [n₀] is [n] with child [m] replaced by [child_then(m)]
      - [n₁] is [n] with child [m] replaced by [child_else(m)]
  *)

  let predicate g v =
    match G.V.label v with
    | If _ -> None
    | Impl _ | App ->
      try
        let e = List.find (fun e -> is_if @@ G.E.dst e) @@ G.succ_e g v in
        Some (v, G.E.dst e)
      with _ -> None

  let apply g (v_impl, v_if) =
    let preds = G.pred_e g v_impl in
    let cond, else_, then_ =
      match explode g v_if with
      | `If x -> x | _ -> assert false
    in
    let succs = G.succ_e g v_impl in
    let v_impl_else = G.V.create (G.V.label v_impl) in
    let v_impl_then = G.V.create (G.V.label v_impl) in

    let g = G.remove_vertex g v_impl in
    let g = add_succ_with_subst g succs v_impl_else ~sub:v_if ~by:else_ in
    let g = add_succ_with_subst g succs v_impl_then ~sub:v_if ~by:then_ in
    let v_if', g = add_if g ~cond ~else_:v_impl_else ~then_:v_impl_then in
    add_pred_with_subst g preds v_if'

end

module RemovePartialApp = struct
  (** Remove [App] nodes.

      The goal here is to remove partial application of functor.
      If we find an [App] node with an implementation as first children,
      We fuse them and create one [Impl] node.
  *)

  let predicate g v = match explode g v with
    | `App (f,args) -> begin match explode g f with
        | `Impl (impl, `Args args', `Deps deps) ->
          Some (v, impl, args' @ args, deps)
        | _ -> None
      end
    | _ -> None

  let apply g (v_app, impl, args, deps) =
    let preds = G.pred_e g v_app in
    let g = G.remove_vertex g v_app in
    let v_impl', g = add_impl g ~impl ~args ~deps in
    add_pred_with_subst g preds v_impl'

end

module EvalIf = struct
  (** Evaluate the [If] nodes and remove them. *)

  let predicate ~partial _ v = match G.V.label v with
    | If cond when not partial || Key.peek cond <> None -> Some v
    | _ -> None

  let apply ~partial g v_if =
    let cond, then_, else_ =
      match explode g v_if with
      | `If x -> x | _ -> assert false
    in
    let preds = G.pred_e g v_if in
    match Key.peek cond with
    | None when partial -> g
    | _ ->
      let v_new, v_rem =
        if Key.eval cond then then_, else_ else else_,then_
      in
      let g = G.remove_vertex g v_if in
      let g = remove_recursively g v_rem in
      add_pred_with_subst g preds v_new

end

let normalize g =
  g
  |> PushIf.(transform ~predicate ~apply)
  |> RemovePartialApp.(transform ~predicate ~apply)

let eval ?(partial=false) g =
  EvalIf.(transform
      ~predicate:(predicate ~partial)
      ~apply:(apply ~partial)
      g)

let is_fully_reduced g =
  for_all_vertex (fun v -> is_impl v) g


(** {2 dot output} *)

module Dot = Graphviz.Dot(struct
    include G
    let graph_attributes _g = []
    let default_vertex_attributes _g = []
    let vertex_name v = match V.label v with
      | App -> "$"
      | If _ -> "If"
      | Impl f -> f#module_name

    let vertex_attributes _v = []

    let get_subgraph _g = None

    let default_edge_attributes _g = []
    let edge_attributes e = match E.label e with
      | Parameter i -> [ `Label (string_of_int i) ]
      | Dependency i -> [ `Label (string_of_int i) ; `Style `Dashed ]
      | Condition _ -> [ `Style `Dotted ]

  end )

let pp_dot = Dot.fprint_graph

let pp = Fmt.nop