(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module F = Format

module Map : Stdlib.Map.S with type key = int

module Set : sig
  include Stdlib.Set.S with type elt = int

  val pp : F.formatter -> t -> unit
end

module Hash : Stdlib.Hashtbl.S with type key = int
