(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

module DirectCallee : sig
  type t = {proc_name: Procname.t; specialization: Specialization.Pulse.t; loc: Location.t}

  module Set : sig
    include PrettyPrintable.PPSet with type elt = t
  end
end

module Callees : sig
  (** for each call site, we remember which resolution was performed *)

  include AbstractDomain.WithBottom

  val pp : Format.formatter -> t -> unit

  (** NOTE: only [Closure] is recorded for now *)
  type call_kind = Static | Virtual | Closure

  type resolution =
    | ResolvedUsingDynamicType  (** the most precise resolution *)
    | ResolvedUsingStaticType  (** may not be exact *)
    | Unresolved
        (** the worst resolution because we don't have enough type information or the capture was
            incomplete *)

  val record : caller:Procdesc.t -> Location.t -> call_kind -> resolution -> t -> t

  val to_jsonbug_transitive_callees : t -> Jsonbug_t.transitive_callee list
end

type t =
  { accesses: PulseTrace.Set.t  (** record specific accesses inter-procedurally *)
  ; callees: Callees.t  (** record all call resolutions that were transitively performed *)
  ; direct_callees: DirectCallee.Set.t  (** record direct callee with specialization key *)
  ; direct_missed_captures: Typ.Name.Set.t
        (** record types that were missing during name resolution (fields/methods) while analysing
            this function (ignoring what happened in callees) *)
  ; has_transitive_missed_captures: AbstractDomain.BooleanOr.t
        (** true iff one the callees of this function has at least one transitively missing type.
            This does not take into account the local [direct_missed_captures] set above. *) }
[@@deriving compare, equal]

include AbstractDomain.WithBottom with type t := t

val apply_summary : callee_pname:Procname.t -> call_loc:Location.t -> summary:t -> t -> t

val add_specialized_direct_callee : Procname.t -> Specialization.Pulse.t -> Location.t -> t -> t

val remember_dropped_elements : dropped:t -> t -> t
