(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
open PyIR

type field_type =
  | Class of {class_name: string; supers: string list}
  | Fundef of {qual_name: string}
  | Import of {module_name: string}
  | ImportFrom of {module_name: string; attr_name: string}

(* note: we only support super class names that are defined in the current Python module *)
type struct_kind = Global | ClassCompanion of {supers: string list}

type field_decl = {name: string; typ: field_type}

type struct_type = {name: string; kind: struct_kind; fields: field_decl list}

type t = struct_type list

let pp_field_typ fmt = function
  | Class {class_name; supers= []} ->
      F.fprintf fmt "Class[%s]" class_name
  | Class {class_name; supers} ->
      F.fprintf fmt "Class[%s][%a]" class_name (Pp.comma_seq F.pp_print_string) supers
  | Import {module_name} ->
      F.fprintf fmt "Import[%s]" module_name
  | ImportFrom {module_name; attr_name} ->
      F.fprintf fmt "ImportFrom[%s, %s]" module_name attr_name
  | Fundef {qual_name} ->
      F.fprintf fmt "Closure[%s]" qual_name


let pp_decl fmt {name; typ} = F.fprintf fmt "%s: %a" name pp_field_typ typ

let pp_struct_type fmt {name; fields} =
  F.fprintf fmt "type %s = {@;<0 4>@[<v>" name ;
  let first_line = ref true in
  let pp_decl decl =
    F.fprintf fmt "%t%a"
      (fun _fmt -> if !first_line then first_line := false else F.print_break 0 0)
      pp_decl decl
  in
  List.iter fields ~f:pp_decl ;
  F.fprintf fmt "@]@.}@.@."


let pp fmt l = List.iter l ~f:(pp_struct_type fmt)

type acc = {var_types: field_type IString.Map.t; exps: field_type SSA.Map.t}

let empty = {var_types= IString.Map.empty; exps= SSA.Map.empty}

let add_decl name typ ({var_types} as acc) = {acc with var_types= IString.Map.add name typ var_types}

let add_fundef id qual_name ({exps} as acc) =
  {acc with exps= SSA.Map.add id (Fundef {qual_name}) exps}


let add_import id module_name ({exps} as acc) =
  {acc with exps= SSA.Map.add id (Import {module_name}) exps}


let add_import_from id ~module_name ~attr_name ({exps} as acc) =
  {acc with exps= SSA.Map.add id (ImportFrom {module_name; attr_name}) exps}


let add_class id class_name supers ({exps} as acc) =
  {acc with exps= SSA.Map.add id (Class {class_name; supers}) exps}


let add_typ id typ ({exps} as acc) = {acc with exps= SSA.Map.add id typ exps}

let is_class id {exps} = match SSA.Map.find_opt id exps with Some (Class _) -> true | _ -> false

let is_fundef id {exps} = match SSA.Map.find_opt id exps with Some (Fundef _) -> true | _ -> false

let is_import id {exps} = match SSA.Map.find_opt id exps with Some (Import _) -> true | _ -> false

let is_import_from id {exps} =
  match SSA.Map.find_opt id exps with Some (ImportFrom _) -> true | _ -> false


let get_class id {exps} =
  match SSA.Map.find_opt id exps with
  | Some (Class {class_name; supers}) ->
      Some (class_name, supers)
  | _ ->
      None


let get_fundef id {exps} =
  match SSA.Map.find_opt id exps with Some (Fundef {qual_name}) -> Some qual_name | _ -> None


let get_var_typ name {var_types} = IString.Map.find_opt name var_types

let get_import id {exps} =
  match SSA.Map.find_opt id exps with Some (Import {module_name}) -> Some module_name | _ -> None


let get_import_from id {exps} =
  match SSA.Map.find_opt id exps with
  | Some (ImportFrom {module_name; attr_name}) ->
      Some (module_name, attr_name)
  | _ ->
      None


let root_of_name str =
  match String.split str ~on:'.' with first :: _ :: _ -> first ^ ".__init__" | _ -> str


let str_of_ident ident = F.asprintf "%a" Ident.pp ident

let gen_type kind name procdesc =
  let rec find_next_declaration acc instrs =
    match instrs with
    | [] ->
        acc
    | (_, instr) :: instrs -> (
      match (instr : Stmt.t) with
      | Let {lhs; rhs= ImportName {name; fromlist= Collection {kind= Tuple}}} ->
          let name = str_of_ident name in
          let acc = add_import lhs name acc in
          find_next_declaration acc instrs
      | Let {lhs; rhs= ImportName {name}} ->
          let name = str_of_ident name |> root_of_name in
          let acc = add_import lhs name acc in
          find_next_declaration acc instrs
      | Let {lhs; rhs= ImportFrom {name; exp= Temp id_module}} when is_import id_module acc ->
          let module_name = get_import id_module acc |> Option.value_exn in
          let attr_name = str_of_ident name in
          let acc = add_import_from lhs ~module_name ~attr_name acc in
          find_next_declaration acc instrs
      | Let {lhs; rhs= ImportFrom {name; exp= Temp id_from}} when is_import_from id_from acc ->
          let module_name, attr_name0 = get_import_from id_from acc |> Option.value_exn in
          let attr_name = str_of_ident name in
          let acc =
            String.chop_suffix module_name ~suffix:"__init__"
            |> Option.value_map ~default:acc ~f:(fun module_name ->
                   let module_name = module_name ^ attr_name0 in
                   add_import_from lhs ~module_name ~attr_name acc )
          in
          find_next_declaration acc instrs
      | Let {lhs; rhs= Function {qual_name}} ->
          let qual_name_str = F.asprintf "%a" QualName.pp qual_name in
          let acc = add_fundef lhs qual_name_str acc in
          find_next_declaration acc instrs
      | Let {lhs; rhs= Var {scope= Name; ident}} -> (
          let name = str_of_ident ident in
          match get_var_typ name acc with
          | None ->
              find_next_declaration acc instrs
          | Some typ ->
              let acc = add_typ lhs typ acc in
              find_next_declaration acc instrs )
      | BuiltinCall {lhs; call= BuildClass; args= _ :: Const (String name) :: supers} ->
          let supers =
            List.filter_map supers ~f:(function
              | Exp.Temp id ->
                  let open IOption.Let_syntax in
                  let+ class_name, _supers = get_class id acc in
                  class_name
              | _ ->
                  None )
          in
          let acc = add_class lhs name supers acc in
          find_next_declaration acc instrs
      | Call {lhs; exp= Temp _id_decorator; args= [Temp id_fun_ptr]} when is_fundef id_fun_ptr acc
        ->
          (* note: we could filter the decorator in id_decorator if needed *)
          let typ = get_fundef id_fun_ptr acc |> Option.value_exn in
          let acc = add_fundef lhs typ acc in
          find_next_declaration acc instrs
      | Call {lhs; exp= Temp _id_decorator; args= [Temp id_class]} when is_class id_class acc ->
          (* note: we could filter the decorator in id_decorator if needed *)
          let name, supers = get_class id_class acc |> Option.value_exn in
          let acc = add_class lhs name supers acc in
          find_next_declaration acc instrs
      | Store {lhs= {scope= Name; ident}; rhs= Temp ident_fun} when is_fundef ident_fun acc ->
          let qual_name = get_fundef ident_fun acc |> Option.value_exn in
          let name = str_of_ident ident in
          let acc = add_decl name (Fundef {qual_name}) acc in
          find_next_declaration acc instrs
      | Store {lhs= {scope= Name; ident}; rhs= Temp ident_import} when is_import ident_import acc ->
          let module_name = get_import ident_import acc |> Option.value_exn in
          let name = str_of_ident ident in
          let acc = add_decl name (Import {module_name}) acc in
          find_next_declaration acc instrs
      | Store {lhs= {scope= Name; ident}; rhs= Temp ident_import_from}
        when is_import_from ident_import_from acc ->
          let module_name, attr_name = get_import_from ident_import_from acc |> Option.value_exn in
          let name = str_of_ident ident in
          let acc = add_decl name (ImportFrom {module_name; attr_name}) acc in
          find_next_declaration acc instrs
      | Store {lhs= {scope= Name; ident}; rhs= Temp ident_class_body}
        when is_class ident_class_body acc ->
          let class_name, supers = get_class ident_class_body acc |> Option.value_exn in
          let name = str_of_ident ident in
          let acc = add_decl name (Class {class_name; supers}) acc in
          find_next_declaration acc instrs
      | _ ->
          find_next_declaration acc instrs )
  in
  let rec find_declarations acc nodes_map nodename =
    NodeName.Map.find_opt nodename nodes_map
    |> Option.value_map ~default:acc ~f:(fun {Node.stmts; last} ->
           let acc = find_next_declaration acc stmts in
           match last with
           | Terminator.Jump {label} ->
               find_declarations acc nodes_map label
           | _ ->
               acc )
  in
  let {CFG.nodes; entry} = procdesc in
  let {var_types} = find_declarations empty nodes entry in
  let is_global = match kind with Global -> true | _ -> false in
  let fields, classes =
    IString.Map.fold
      (fun name typ (fields, classes) ->
        match typ with
        | Class {class_name; supers} when is_global ->
            ({name; typ} :: fields, (class_name, supers) :: classes)
        | Class {class_name; supers} ->
            (fields, (class_name, supers) :: classes)
        | Import _ | ImportFrom _ | Fundef _ ->
            ({name; typ} :: fields, classes) )
      var_types ([], [])
  in
  ({name; kind; fields}, classes)


let gen_module_default_type {Module.name; toplevel; functions} =
  let open IOption.Let_syntax in
  let name_str = F.asprintf "%a" Ident.pp name in
  let default_type, classes = gen_type Global name_str toplevel in
  let* other_type_decls =
    List.fold classes ~init:(Some []) ~f:(fun decls (classname, supers) ->
        let* decls in
        let ident = Ident.mk classname in
        let qual_name = {QualName.module_name= name; function_name= ident} in
        let+ class_body_procdesc = QualName.Map.find_opt qual_name functions in
        let type_decl, _ = gen_type (ClassCompanion {supers}) classname class_body_procdesc in
        type_decl :: decls )
  in
  Some (default_type :: other_type_decls)


let gen_module_default_type_debug module_ =
  gen_module_default_type module_ |> Option.iter ~f:(pp F.std_formatter)
