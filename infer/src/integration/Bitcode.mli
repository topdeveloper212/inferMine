(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type compiler = Clang | Swiftc

val capture : compiler -> command:string -> args:string list -> unit

val capture_llair : source_file:string -> llair_file:string -> unit

val direct_bitcode_capture : sources:string list -> bitcode:string -> unit
