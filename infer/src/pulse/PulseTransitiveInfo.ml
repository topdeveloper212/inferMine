(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

module Callees = struct
  type call_kind = Static | Virtual | Closure [@@deriving equal, compare]

  type resolution = ResolvedUsingDynamicType | ResolvedUsingStaticType | Unresolved
  [@@deriving equal, compare]

  module CallSite = struct
    type t =
      { callsite_loc: Location.t
      ; caller_name: (Procname.t[@compare.ignore])
      ; caller_loc: (Location.t[@compare.ignore]) }
    [@@deriving compare]

    let pp fmt {callsite_loc} = Location.pp_file_pos fmt callsite_loc
  end

  module Status = struct
    type kind = call_kind [@@deriving equal, compare]

    type t = {kind: kind; resolution: resolution} [@@deriving equal, compare]

    let pp fmt {kind; resolution} =
      let kind =
        match kind with Static -> "static" | Virtual -> "virtual" | Closure -> "closure"
      in
      let resolution =
        match resolution with
        | Unresolved ->
            "unresolved"
        | ResolvedUsingDynamicType ->
            "resolved using receiver dynamic type"
        | ResolvedUsingStaticType ->
            "resolved using receiver static type"
      in
      F.fprintf fmt "%s call was %s" kind resolution


    (* this is a total order *)
    let leq ~lhs ~rhs =
      if equal lhs rhs then true
      else
        match (lhs.resolution, rhs.resolution) with
        | _, ResolvedUsingDynamicType | Unresolved, _ ->
            false
        | _, _ ->
            true


    let join lhs rhs = if leq ~lhs ~rhs then rhs else lhs

    let widen ~prev ~next ~num_iters:_ = join prev next
  end

  module Map = AbstractDomain.Map (CallSite) (Status)

  let record ~caller callsite_loc kind resolution history =
    let callsite =
      { CallSite.caller_name= Procdesc.get_proc_name caller
      ; caller_loc= Procdesc.get_loc caller
      ; callsite_loc }
    in
    Map.add callsite {kind; resolution} history


  let to_jsonbug_kind = function Static -> `Static | Virtual -> `Virtual | Closure -> `Closure

  let to_jsonbug_resolution = function
    | ResolvedUsingDynamicType ->
        `ResolvedUsingDynamicType
    | ResolvedUsingStaticType ->
        `ResolvedUsingStaticType
    | Unresolved ->
        `Unresolved


  let to_jsonbug_transitive_callees history =
    Map.fold
      (fun {callsite_loc; caller_name; caller_loc} ({kind; resolution} : Status.t) acc :
           Jsonbug_t.transitive_callee list ->
        let callsite_filename = SourceFile.to_abs_path callsite_loc.file in
        let callsite_absolute_position_in_file = callsite_loc.line in
        let callsite_relative_position_in_caller = callsite_loc.line - caller_loc.line in
        { callsite_filename
        ; callsite_absolute_position_in_file
        ; caller_name= Procname.get_method caller_name
        ; callsite_relative_position_in_caller
        ; kind= to_jsonbug_kind kind
        ; resolution= to_jsonbug_resolution resolution }
        :: acc )
      history []


  include Map

  let compare = Map.compare Status.compare

  let equal = Map.equal Status.equal
end

module DirectCallee = struct
  type t = {proc_name: Procname.t; specialization: Specialization.Pulse.t; loc: Location.t}
  [@@deriving equal, compare]

  let pp fmt {proc_name; specialization} =
    F.fprintf fmt "%a (specialized for %a)" Procname.pp proc_name Specialization.Pulse.pp
      specialization


  module Set = struct
    include AbstractDomain.FiniteSet (struct
      type nonrec t = t

      let compare = compare

      let pp = pp
    end)
  end
end

module Accesses = AbstractDomain.FiniteSetOfPPSet (PulseTrace.Set)
module MissedCaptures = AbstractDomain.FiniteSetOfPPSet (Typ.Name.Set)

type t =
  { accesses: Accesses.t
  ; callees: Callees.t
  ; direct_callees: DirectCallee.Set.t
  ; direct_missed_captures: MissedCaptures.t
  ; has_transitive_missed_captures: AbstractDomain.BooleanOr.t }
[@@deriving abstract_domain, compare, equal]

let pp fmt
    {accesses; callees; direct_callees; direct_missed_captures; has_transitive_missed_captures} =
  F.fprintf fmt
    "@[@[accesses: %a@],@ @[callees: %a@],@ @[direct_callees: %a@],@ @[direct_missed captures: \
     %a@],@ @[has_transitive_missed_captures: %b@]@]"
    Accesses.pp accesses Callees.pp callees DirectCallee.Set.pp direct_callees Typ.Name.Set.pp
    direct_missed_captures has_transitive_missed_captures


let bottom =
  { accesses= Accesses.empty
  ; callees= Callees.bottom
  ; direct_callees= DirectCallee.Set.empty
  ; direct_missed_captures= Typ.Name.Set.empty
  ; has_transitive_missed_captures= false }


let is_bottom
    {accesses; callees; direct_callees; direct_missed_captures; has_transitive_missed_captures} =
  Accesses.is_bottom accesses && Callees.is_bottom callees
  && DirectCallee.Set.is_empty direct_callees
  && Typ.Name.Set.is_empty direct_missed_captures
  && not has_transitive_missed_captures


let remember_dropped_elements ~dropped
    {accesses; callees; direct_callees; direct_missed_captures; has_transitive_missed_captures} =
  let accesses = Accesses.union dropped.accesses accesses in
  let callees = Callees.join dropped.callees callees in
  let direct_callees = DirectCallee.Set.union dropped.direct_callees direct_callees in
  let direct_missed_captures =
    Typ.Name.Set.union dropped.direct_missed_captures direct_missed_captures
  in
  let has_transitive_missed_captures =
    dropped.has_transitive_missed_captures || has_transitive_missed_captures
  in
  {accesses; callees; direct_callees; direct_missed_captures; has_transitive_missed_captures}


let add_specialized_direct_callee proc_name specialization loc ({direct_callees} as transitive_info)
    =
  { transitive_info with
    direct_callees=
      DirectCallee.Set.add {DirectCallee.proc_name; specialization; loc} direct_callees }


let apply_summary ~callee_pname ~call_loc ~summary
    {accesses; callees; direct_callees; direct_missed_captures; has_transitive_missed_captures} =
  let accesses =
    PulseTrace.Set.map_callee (Call callee_pname) call_loc summary.accesses
    |> PulseTrace.Set.union accesses
  in
  let callees = Callees.join callees summary.callees in
  let has_transitive_missed_captures =
    summary.has_transitive_missed_captures
    || (not (MissedCaptures.is_empty summary.direct_missed_captures))
    || has_transitive_missed_captures
  in
  {accesses; callees; direct_callees; direct_missed_captures; has_transitive_missed_captures}
