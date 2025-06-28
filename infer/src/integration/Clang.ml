(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module L = Logging

type compiler = Clang | Make [@@deriving compare]

let capture compiler ~prog ~args =
  match compiler with
  | Clang ->
      ClangWrapper.exe ~prog ~args
  | Make ->
      let path_var = "PATH" in
      let old_path = Option.value ~default:"" (Sys.getenv path_var) in
      let new_path = Config.wrappers_dir ^ ":" ^ old_path in
      let extended_env = `Extend [(path_var, new_path); ("INFER_OLD_PATH", old_path)] in
      L.environment_info "Running command %s with env:@\n%s@\n@." prog
        (IUnix.Env.sexp_of_t extended_env |> Sexp.to_string) ;
      Process.create_process_and_wait ~prog ~args ~env:extended_env ()
