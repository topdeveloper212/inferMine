(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type count_entry_data = {value: int}

type time_entry_data = {duration_us: int}

type string_data = {message: string}

type entry_data = Count of count_entry_data | Time of time_entry_data | String of string_data

type t = {label: string; created_at_ts: int; data: entry_data}

let mk_count ~label ~value =
  let created_at_ts = Unix.time () |> int_of_float in
  let data = Count {value} in
  {label; created_at_ts; data}


let mk_time ~label ~duration_us =
  let created_at_ts = Unix.time () |> int_of_float in
  let data = Time {duration_us} in
  {label; created_at_ts; data}


let mk_string ~label ~message =
  let created_at_ts = Unix.time () |> int_of_float in
  let data = String {message} in
  {label; created_at_ts; data}
