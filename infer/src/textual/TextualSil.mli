(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

val proc_decl_to_sil : Textual.Lang.t -> Textual.ProcDecl.t -> Procname.t
[@@warning "-unused-value-declaration"]

val module_to_sil :
     Textual.Lang.t
  -> Textual.Module.t
  -> TextualDecls.t
  -> (Cfg.t * Tenv.t, Textual.transform_error list) result
(** convert a Textual unit into Infer internal representation (cfg + tenv). During the process the
    textual representation undergoes several transformations. The result is passed as the third
    element of the returned tuple *)

val from_java : filename:string -> Tenv.t -> Cfg.t -> unit
(** generate a .sil file with name [filename] containing all the functions in the given cfg *)

val dump_module : show_location:bool -> filename:string -> Textual.Module.t -> unit
(** generate a .sil file with name [filename] with all the content of the input module *)

val default_return_type : Textual.Lang.t -> Textual.Location.t -> Textual.Typ.t

val hack_dict_type_name : Typ.name

val hack_dict_iter_type_name : Typ.name

val hack_vec_type_name : Typ.name

val hack_vec_iter_type_name : Typ.name

val hack_bool_type_name : Typ.name

val hack_int_type_name : Typ.name

val hack_float_type_name : Typ.name

val hack_string_type_name : Typ.name

val hack_splated_vec_type_name : Typ.name

val hack_mixed_type_name : Typ.name

val hack_awaitable_type_name : Typ.name

val hack_mixed_static_companion_type_name : Typ.name

val hack_builtins_type_name : Typ.name

val hack_root_type_name : Typ.name

val python_bool_type_name : Typ.name

val python_dict_type_name : Typ.name

val python_int_type_name : Typ.name

val python_string_type_name : Typ.name

val python_none_type_name : Typ.name

val python_mixed_type_name : Typ.name

val python_tuple_type_name : Typ.name

val wildcard_sil_fieldname : Textual.Lang.t -> string -> Fieldname.t

val textual_ext : string
(* Extension used by Textual files *)

val to_filename : string -> string
(* Normalize and flatten an input path into a file name *)
