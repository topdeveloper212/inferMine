(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
open PulseBasicInterface

(** the trace represents the start of a cycle but isn't a cycle yet, it's a sequence of calls that
    end where ondemand returned no summary due to mutual recursion; these proto-cycles get bubbled
    the cyclic call stack until the cycle is closed again *)
type t [@@deriving equal]

val mk : Location.t -> Procname.t -> AbstractValue.t list -> t
(** a trace of length 1 *)

val get_inner_call : t -> Procname.t
(** the "initial", innermost call in the cycle *)

val get_outer_location : t -> Location.t
(** the location of the first call in the cycle *)

val add_call :
     (AbstractValue.t * ValueHistory.t) AbstractValue.Map.t
  -> Procname.t
  -> Location.t
  -> t
  -> t option

val iter_rotations : t -> f:(t -> unit) -> unit

val pp : F.formatter -> t -> unit

val get_error_message : t -> is_call_with_same_values:bool -> string

val to_errlog : t -> is_call_with_same_values:bool -> Errlog.loc_trace

module Set : PrettyPrintable.PPSet with type elt = t
