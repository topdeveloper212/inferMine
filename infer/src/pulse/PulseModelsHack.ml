(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging
open PulseBasicInterface
open PulseDomainInterface
open PulseOperationResult.Import
open PulseModelsImport
module DSL = PulseModelsDSL

let awaitable_type_name = TextualSil.hack_awaitable_type_name

let hack_bool_type_name = TextualSil.hack_bool_type_name

let hack_int_type_name = TextualSil.hack_int_type_name

let hack_float_type_name = TextualSil.hack_float_type_name

let mixed_type_name = TextualSil.hack_mixed_type_name

let hack_string_type_name = TextualSil.hack_string_type_name

let string_val_field = Fieldname.make hack_string_type_name "val"

let read_string_value address astate = PulseArithmetic.as_constant_string astate address

let replace_backslash_with_colon s = String.tr s ~target:'\\' ~replacement:':'

let read_string_value_dsl aval : string option DSL.model_monad =
  let open PulseModelsDSL.Syntax in
  let* inner_val = load_access aval (FieldAccess string_val_field) in
  let operation astate = (read_string_value (fst inner_val) astate, astate) in
  let* opt_string = exec_operation operation in
  ret opt_string


let await_hack_value aval : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let val_field = Fieldname.make awaitable_type_name "val" in
  dynamic_dispatch aval
    ~cases:
      [ ( awaitable_type_name
        , fun () ->
            let* () = fst aval |> AddressAttributes.await_awaitable |> DSL.Syntax.exec_command in
            load_access aval (FieldAccess val_field) ) ]
    ~default:(fun () -> ret aval)


let hack_await arg : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* rv = await_hack_value arg in
  assign_ret rv


let hack_await_static _ arg : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* rv = await_hack_value arg in
  assign_ret rv


let make_new_awaitable av =
  let open DSL.Syntax in
  let* av = constructor awaitable_type_name [("val", av)] in
  allocation Attribute.Awaitable av @@> ret av


let deep_clean_hack_value aval : unit DSL.model_monad =
  let open DSL.Syntax in
  let* reachable_addresses =
    exec_pure_operation (fun astate ->
        AbductiveDomain.reachable_addresses_from (Seq.return (fst aval)) astate `Post )
  in
  absvalue_set_iter reachable_addresses ~f:(fun absval ->
      let* _v = await_hack_value (absval, ValueHistory.epoch) in
      let* () =
        AddressAttributes.set_hack_builder absval Attribute.Builder.Discardable |> exec_command
      in
      ret () )


(* vecs, similar treatment of Java collections, though these are value types
   Should be shared with dict (and keyset) but will generalise later.
   We have an integer size field (rather than just an empty flag) and a
   last_read field, which is 1 or 2 if we last produced the fst or snd field
   as the result of an index operation. This is used to alternate returned values
   so as to remove paths in which we assign_ret the same value repeatedly, which leads
   to false awaitable positives because the *other* value is never awaited.
   TODO: a more principled approach to collections of resources.
*)
module Vec = struct
  let type_name = TextualSil.hack_vec_type_name

  let mk_vec_field name = Fieldname.make type_name name

  let fst_field_name = "__infer_model_backing_vec_fst"

  let snd_field_name = "__infer_model_backing_vec_snd"

  let size_field_name = "__infer_model_backing_vec_size"

  let last_read_field_name = "__infer_model_backing_last_read"

  let fst_field = mk_vec_field fst_field_name

  let snd_field = mk_vec_field snd_field_name

  let size_field = mk_vec_field size_field_name

  let last_read_field = mk_vec_field last_read_field_name

  let new_vec_dsl ?(know_size = None) args : DSL.aval DSL.model_monad =
    let open DSL.Syntax in
    let actual_size = List.length args in
    let* size = match know_size with None -> int actual_size | Some size -> ret size in
    let* last_read = fresh () in
    let* dummy = int 9 in
    let* vec =
      constructor type_name
        [ (fst_field_name, dummy)
        ; (snd_field_name, dummy)
        ; (size_field_name, size)
        ; (last_read_field_name, last_read) ]
    in
    ( match args with
    | [] ->
        store_field ~ref:vec snd_field dummy
    | arg1 :: rest -> (
        store_field ~ref:vec fst_field arg1
        @@>
        match rest with
        | [] ->
            ret ()
        | arg2 :: rest -> (
            store_field ~ref:vec snd_field arg2
            @@>
            match rest with
            | [] ->
                ret ()
            (* Do "fake" await on the values we drop on the floor. TODO: mark reachable too? *)
            | rest ->
                list_iter rest ~f:deep_clean_hack_value ) ) )
    @@> ret vec


  let new_vec args : model =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* vec = new_vec_dsl args in
    assign_ret vec


  (* TODO: this isn't *quite* right with respect to dummy values, but int think it's OK *)
  let vec_from_async _dummy aval : model =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* fst_val = load_access aval (FieldAccess fst_field) in
    let* snd_val = load_access aval (FieldAccess snd_field) in
    let* awaited_fst_val = await_hack_value fst_val in
    let* awaited_snd_val = await_hack_value snd_val in
    let* fresh_vec = new_vec_dsl [awaited_fst_val; awaited_snd_val] in
    assign_ret fresh_vec


  let map _this arg closure =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* size_val = load_access arg (FieldAccess size_field) in
    let size_eq_0_case : DSL.aval DSL.model_monad = prune_eq_zero size_val @@> new_vec_dsl [] in
    let size_eq_1_case : DSL.aval DSL.model_monad =
      prune_eq_int size_val IntLit.one
      @@>
      let* fst_val = load_access arg (FieldAccess fst_field) in
      let* mapped_fst_val = apply_hack_closure closure [fst_val] in
      new_vec_dsl [mapped_fst_val]
    in
    let size_gt_1_case : DSL.aval DSL.model_monad =
      prune_gt_int size_val IntLit.one
      @@>
      let* fst_val = load_access arg (FieldAccess fst_field) in
      let* snd_val = load_access arg (FieldAccess snd_field) in
      let* mapped_fst_val = apply_hack_closure closure [fst_val] in
      let* mapped_snd_val = apply_hack_closure closure [snd_val] in
      new_vec_dsl ~know_size:(Some size_val) [mapped_fst_val; mapped_snd_val]
    in
    let* ret = disj [size_eq_0_case; size_eq_1_case; size_gt_1_case] in
    assign_ret ret


  let get_vec_dsl argv _index : DSL.aval DSL.model_monad =
    let open DSL.Syntax in
    let* ret_val = fresh () in
    let* new_last_read_val = fresh () in
    let* _size_val = load_access argv (FieldAccess size_field) in
    let* fst_val = load_access argv (FieldAccess fst_field) in
    let* snd_val = load_access argv (FieldAccess snd_field) in
    let* last_read_val = load_access argv (FieldAccess last_read_field) in
    store_field ~ref:argv last_read_field new_last_read_val
    (* Don't assign_ret dummy value *)
    (* TODO: assert index < size_val ? *)
    @@> prune_ne_int ret_val (IntLit.of_int 9)
    @@>
    (* TODO: work out how to incorporate type-based, or at least nullability, assertions on ret_val *)
    (* Temporarily removing the "or something else" case1 (which follows the Java collection models)
       because I'm unconvinced it's a net benefit, and it leads to more disjuncts.
       Will experiment later. *)
    let case2 : DSL.aval DSL.model_monad =
      (* case 2: given element is equal to fst_field *)
      prune_eq_int last_read_val IntLit.two
      @@> and_eq ret_val fst_val
      @@> and_eq_int new_last_read_val IntLit.one
      @@> ret ret_val
    in
    let case3 : DSL.aval DSL.model_monad =
      (* case 3: given element is equal to snd_field *)
      prune_eq_int last_read_val IntLit.one
      @@> and_eq ret_val snd_val
      @@> and_eq_int new_last_read_val IntLit.two
      @@> ret ret_val
    in
    disj [(* case1; *) case2; case3]


  let hack_array_get_one_dim vec key : DSL.aval DSL.model_monad =
    let open DSL.Syntax in
    let* key_type = get_dynamic_type ~ask_specialization:false key in
    option_iter key_type ~f:(fun {Formula.typ} ->
        match typ with
        | {desc= Tstruct type_name} when not (Typ.Name.equal type_name hack_int_type_name) ->
            let* {location} = get_data in
            report (Diagnostic.DynamicTypeMismatch {location})
        | _ ->
            ret () )
    @@>
    let field = Fieldname.make hack_int_type_name "val" in
    let* index = load_access key (FieldAccess field) in
    get_vec_dsl vec index


  let hack_array_idx vec key default : unit DSL.model_monad =
    let open DSL.Syntax in
    let field = Fieldname.make hack_int_type_name "val" in
    let* index = load_access key (FieldAccess field) in
    let value = get_vec_dsl vec index in
    let* ret_values = disj [value; ret default] in
    assign_ret ret_values


  (*
  See also $builtins.hack_array_cow_append in lib/hack/models.sil
  Model of set is very like that of append, since it ignores the index
  *)
  let hack_array_cow_set_dsl vec args : unit DSL.model_monad =
    let open DSL.Syntax in
    match args with
    | [_key; value] ->
        let* v_fst = load_access vec (FieldAccess fst_field) in
        let* v_snd = load_access vec (FieldAccess snd_field) in
        deep_clean_hack_value v_fst
        @@>
        let* new_vec = new_vec_dsl [v_snd; value] in
        let* size = load_access vec (FieldAccess size_field) in
        store_field ~ref:new_vec size_field size
        @@> (* overwrite default size of 2 *)
        assign_ret new_vec
    | _ ->
        L.d_printfln "vec hack array cow set argument error" ;
        L.internal_error "Vec.hack_array_cow_set expects 1 key and 1 value arguments@\n" ;
        ret ()
end

let bool_val_field = Fieldname.make hack_bool_type_name "val"

let make_hack_bool bool : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* bool = int (if bool then 1 else 0) in
  let* boxed_bool = constructor hack_bool_type_name [("val", bool)] in
  ret boxed_bool


let aval_to_hack_int n_val : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* ret_val = constructor hack_int_type_name [("val", n_val)] in
  ret ret_val


let aval_to_hack_bool b_val : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* ret_val = constructor hack_bool_type_name [("val", b_val)] in
  ret ret_val


let zero_test_to_hack_bool v : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* zero = int 0 in
  let* internal_val = binop Binop.Eq v zero in
  aval_to_hack_bool internal_val


let hhbc_is_type_null v : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* ret_val = zero_test_to_hack_bool v in
  assign_ret ret_val


let hack_string_dsl str_val : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* ret_val = constructor hack_string_type_name [("val", str_val)] in
  ret ret_val


let hack_string str_val : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* str_val = hack_string_dsl str_val in
  assign_ret str_val


let make_hack_string (str : string) : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  hack_string_dsl @= string str


module VecIter = struct
  let type_name = TextualSil.hack_vec_iter_type_name

  let mk_vec_iter_field name = Fieldname.make type_name name

  let index_field_name = "__infer_model_backing_veciterator_index"

  let index_field = mk_vec_iter_field index_field_name

  let iter_init_vec iter_addr vec : unit DSL.model_monad =
    let open DSL.Syntax in
    let* size_val = load_access vec (FieldAccess Vec.size_field) in
    let emptycase = prune_eq_zero size_val @@> make_hack_bool false in
    let nonemptycase =
      prune_positive size_val
      @@>
      let* zero = int 0 in
      let* iter = constructor type_name [(index_field_name, zero)] in
      store ~ref:iter_addr iter @@> make_hack_bool true
    in
    let* ret_val = disj [emptycase; nonemptycase] in
    assign_ret ret_val


  let iter_get_key iter _vec : unit DSL.model_monad =
    let open DSL.Syntax in
    let* index = load_access iter (FieldAccess index_field) in
    assign_ret index


  let iter_get_value iter vec : unit DSL.model_monad =
    let open DSL.Syntax in
    let* index = load_access iter (FieldAccess index_field) in
    let* hack_index = aval_to_hack_int index in
    let* value = Vec.get_vec_dsl vec hack_index in
    assign_ret value


  let iter_next_vec iter vec : unit DSL.model_monad =
    let open DSL.Syntax in
    let* size = load_access vec (FieldAccess Vec.size_field) in
    let* index = load_access iter (FieldAccess index_field) in
    let* succindex = binop_int (PlusA None) index IntLit.one in
    (* true loop exit condition *)
    let finished1 = prune_ge succindex size @@> make_hack_bool true in
    (* overapproximate loop exit condition *)
    let finished2 = prune_ge_int succindex IntLit.two @@> make_hack_bool true in
    let not_finished =
      prune_lt succindex size @@> prune_lt_int succindex IntLit.two
      @@> store_field ~ref:iter index_field succindex
      @@> make_hack_bool false
    in
    let* ret_val = disj [finished1; finished2; not_finished] in
    assign_ret ret_val
end

let get_static_companion_var type_name =
  let static_type_name = Typ.Name.Hack.static_companion type_name in
  Pvar.mk_global (Mangled.from_string (Typ.Name.name static_type_name))


let get_static_companion ~model_desc path location type_name astate =
  let pvar = get_static_companion_var type_name in
  let var = Var.of_pvar pvar in
  let hist = Hist.single_call path location model_desc in
  let astate, vo = AbductiveDomain.Stack.eval hist var astate in
  let static_type_name = Typ.Name.Hack.static_companion type_name in
  let typ = Typ.mk_struct static_type_name in
  let ((addr, _) as addr_hist) = ValueOrigin.addr_hist vo in
  let astate = PulseArithmetic.and_dynamic_type_is_unsafe addr typ location astate in
  (addr_hist, astate)


let get_static_companion_dsl ~model_desc type_name : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* {path; location} = get_data in
  exec_operation (get_static_companion ~model_desc path location type_name)


(* TODO: refactor to remove copy-pasta *)
let constinit_existing_class_object static_companion : unit DSL.model_monad =
  let open DSL.Syntax in
  let* typ_opt = get_dynamic_type ~ask_specialization:true static_companion in
  match typ_opt with
  | Some {Formula.typ= {desc= Tstruct type_name}} -> (
      let origin_name = Typ.Name.Hack.static_companion_origin type_name in
      match origin_name with
      | HackClass hack_origin_name ->
          let pvar = get_static_companion_var origin_name in
          let exp = Exp.Lvar pvar in
          let ret_id = Ident.create_none () in
          let ret_typ = Typ.mk_ptr (Typ.mk_struct mixed_type_name) in
          let* {analysis_data= {tenv}} = get_data in
          let is_trait = Option.exists (Tenv.lookup tenv type_name) ~f:Struct.is_hack_trait in
          let constinit_pname = Procname.get_hack_static_constinit ~is_trait hack_origin_name in
          let typ = Typ.mk_struct type_name in
          let arg_payload =
            ValueOrigin.OnStack {var= Var.of_pvar pvar; addr_hist= static_companion}
          in
          dispatch_call (ret_id, ret_typ) constinit_pname [{exp; typ; arg_payload}]
      | _ ->
          ret () )
  | _ ->
      ret ()


(* We no longer call _86sinit at all, but still call _86constinit.
   We keep the is_hack_constinit_called mechanism around in an attempt to
   avoid *too* many redundant calls to constinit
*)
let get_initialized_class_object (type_name : Typ.name) : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* class_object = get_static_companion_dsl ~model_desc:"lazy_class_initialize" type_name in
  ( match type_name with
  | HackClass class_name -> (
      let* {analysis_data= {tenv}} = get_data in
      let all_supers =
        Tenv.fold_supers ~ignore_require_extends:true tenv type_name ~init:[]
          ~f:(fun name _struct_opt accum -> name :: accum )
      in
      L.d_printfln "supers list = %a" (Pp.seq Typ.Name.pp) all_supers ;
      (* Set constinit_called attribute all the way up the hierarchy.
         The set of types on which the attribute is set should always be
         upwards closed.
         The final values returned correspond to the original type_name, at
         the bottom *)
      let* is_constinit_called_and_static_companion_opt =
        list_fold all_supers ~init:None ~f:(fun _accum type_name ->
            let pvar = get_static_companion_var type_name in
            let exp = Exp.Lvar pvar in
            let* static_companion = read exp in
            let* is_constinit_called = is_hack_constinit_called static_companion in
            let* () =
              if not is_constinit_called then set_hack_constinit_called static_companion else ret ()
            in
            ret (Some (is_constinit_called, static_companion, pvar, exp)) )
      in
      match is_constinit_called_and_static_companion_opt with
      | None ->
          ret ()
      | Some (is_constinit_called, static_companion, pvar, exp) ->
          if is_constinit_called then (
            L.d_printfln "skipping consinit call on %a" Typ.Name.pp type_name ;
            ret () )
          else (
            L.d_printfln "calling consinit on %a" Typ.Name.pp type_name ;
            (* If constinit wasn't previously called on type_name, call it. The code emitted by hackc will
                itself call other constinits up the hierarchy, so no looping needed here *)
            let ret_id = Ident.create_none () in
            let ret_typ = Typ.mk_ptr (Typ.mk_struct mixed_type_name) in
            let is_trait = Option.exists (Tenv.lookup tenv type_name) ~f:Struct.is_hack_trait in
            let constinit_pname = Procname.get_hack_static_constinit ~is_trait class_name in
            let typ = Typ.mk_struct type_name in
            let arg_payload =
              ValueOrigin.OnStack {var= Var.of_pvar pvar; addr_hist= static_companion}
            in
            dispatch_call (ret_id, ret_typ) constinit_pname [{exp; typ; arg_payload}] ) )
  | _ ->
      ret () )
  @@> ret class_object


let lazy_class_initialize size_exp : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let type_name =
    match size_exp with
    | Exp.Sizeof {typ= {desc= Typ.Tstruct type_name}} ->
        type_name
    | _ ->
        L.die InternalError
          "lazy_class_initialize: the Hack frontend should never generate such argument type"
  in
  let* class_object = get_initialized_class_object type_name in
  assign_ret class_object


let get_static_class aval : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* opt_dynamic_type_data = get_dynamic_type ~ask_specialization:true aval in
  match opt_dynamic_type_data with
  | Some {Formula.typ= {desc= Tstruct type_name}} ->
      let* class_object = get_static_companion_dsl ~model_desc:"get_static_class" type_name in
      register_class_object_for_value aval class_object @@> assign_ret class_object
  | _ ->
      let* unknown_class_object = fresh () in
      register_class_object_for_value aval unknown_class_object @@> assign_ret unknown_class_object


let hhbc_class_get_c value : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let default () = get_static_class value |> lift_to_monad in
  dynamic_dispatch value
    ~cases:
      [ ( hack_string_type_name
        , fun () ->
            let* opt_string = read_string_value_dsl value in
            match opt_string with
            | Some string ->
                (* namespace\\classname becomes namespace::classname *)
                let string = replace_backslash_with_colon string in
                let typ_name = Typ.HackClass (HackClassName.make string) in
                let* class_object =
                  get_static_companion_dsl ~model_desc:"hhbc_class_get_c" typ_name
                in
                assign_ret class_object
            | None ->
                default () ) ]
    ~default


module Dict = struct
  (* We model dict/shape keys as fields. This is a bit unorthodox in Pulse, but we need
     maximum precision on this ubiquitous Hack data structure. *)

  let type_name = TextualSil.hack_dict_type_name

  let field_of_string = TextualSil.wildcard_sil_fieldname Hack

  let field_of_string_value value : Fieldname.t option DSL.model_monad =
    let open DSL.Syntax in
    let* string = read_string_value_dsl value in
    ret (Option.map string ~f:(fun string -> field_of_string string))


  let read_dict_field_with_check dict field : DSL.aval DSL.model_monad =
    let open DSL.Syntax in
    add_dict_read_const_key dict field @@> load_access dict (FieldAccess field)


  let get_bindings values : ((string * DSL.aval) list * bool) DSL.model_monad =
    let open DSL.Syntax in
    let chunked = List.chunks_of ~length:2 values in
    let const_strings_only = ref true in
    let* res =
      list_filter_map chunked ~f:(fun chunk ->
          let* res =
            match chunk with
            | [string; value] ->
                let* string = read_string_value_dsl string in
                ret (Option.map string ~f:(fun string -> (string, value)))
            | _ ->
                ret None
          in
          if Option.is_none res then const_strings_only := false ;
          ret res )
    in
    ret (res, !const_strings_only)


  (* TODO: handle integers keys *)
  let new_dict args : model =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* bindings, const_strings_only = get_bindings args in
    let* dict = construct_dict ~field_of_string type_name bindings ~const_strings_only in
    assign_ret dict


  let dict_from_async _dummy dict : model =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* fields = get_known_fields dict in
    let* new_dict = constructor type_name [] in
    list_iter fields ~f:(fun field_access ->
        match (field_access : Access.t) with
        | FieldAccess field_name ->
            let* awaitable_value = read_dict_field_with_check dict field_name in
            let* awaited_value = await_hack_value awaitable_value in
            store_field ~ref:new_dict field_name awaited_value
        | _ ->
            ret () )
    @@> assign_ret new_dict


  let hack_add_elem_c_dsl dict key value : unit DSL.model_monad =
    let open DSL.Syntax in
    let* field = field_of_string_value key in
    ( match field with
    | None ->
        remove_dict_contain_const_keys dict
    | Some field ->
        store_field ~ref:dict field value )
    @@> assign_ret dict


  let contains_key dict key : model =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* field = field_of_string_value key in
    match field with
    | None ->
        ret ()
    | Some field ->
        let no_key : unit DSL.model_monad =
          let* ret_val = make_hack_bool false in
          assign_ret ret_val
        in
        let has_key : unit DSL.model_monad =
          let* _v =
            (* This makes the abstract value of `dict` to have `field`. *)
            let* dict_val = access NoAccess dict (FieldAccess field) in
            access NoAccess dict_val Dereference
          in
          let* ret_val = make_hack_bool true in
          assign_ret ret_val
        in
        disj [no_key; has_key]


  (* TODO: handle the situation where we have mix of dict and vec *)
  let hack_array_cow_set_dsl dict args : unit DSL.model_monad =
    let open DSL.Syntax in
    (* args = [key1; key2; ...; key; value] *)
    let len_args = List.length args in
    match List.split_n args (len_args - 2) with
    | keys, [key; value] ->
        let* copy = deep_copy ~depth_max:1 dict in
        let* inner_dict =
          list_fold keys ~init:copy ~f:(fun dict key ->
              let* field = field_of_string_value key in
              match field with
              | Some field ->
                  let* inner_dict = read_dict_field_with_check dict field in
                  let* copied_inned_dict = deep_copy ~depth_max:1 inner_dict in
                  store_field ~ref:dict field copied_inned_dict @@> ret copied_inned_dict
              | None ->
                  fresh () )
        in
        let* field = field_of_string_value key in
        ( match field with
        | None ->
            remove_dict_contain_const_keys inner_dict @@> deep_clean_hack_value value
        | Some field ->
            store_field field ~ref:inner_dict value )
        @@> assign_ret copy
    | _ when List.length args > 2 ->
        L.d_printfln "multidimensional copy on write not implemented yet" ;
        unreachable
    | _ ->
        L.die InternalError "should not happen"


  let hack_array_get_one_dim dict key : DSL.aval DSL.model_monad =
    let open DSL.Syntax in
    (* TODO: a key for a non-vec could be also a int *)
    let* field = field_of_string_value key in
    match field with Some field -> read_dict_field_with_check dict field | None -> fresh ()


  let hack_array_idx dict key default : unit DSL.model_monad =
    let open DSL.Syntax in
    let* field = field_of_string_value key in
    let value =
      match field with Some field -> load_access dict (FieldAccess field) | None -> fresh ()
    in
    let* ret_values = disj [value; ret default] in
    assign_ret ret_values
end

module DictIter = struct
  let type_name = TextualSil.hack_dict_iter_type_name

  let mk_dict_iter_field name = Fieldname.make type_name name

  let index_field_name = "__infer_model_backing_dictiterator_index"

  let index_field = mk_dict_iter_field index_field_name

  let iter_init_dict iter_addr dict : unit DSL.model_monad =
    let open DSL.Syntax in
    let* fields = get_known_fields dict in
    let* size_val = int (List.length fields) in
    let emptycase = prune_eq_zero size_val @@> make_hack_bool false in
    let nonemptycase =
      prune_positive size_val
      @@>
      let* zero = int 0 in
      let* iter = constructor type_name [(index_field_name, zero)] in
      store ~ref:iter_addr iter @@> make_hack_bool true
    in
    let* ret_val = disj [emptycase; nonemptycase] in
    assign_ret ret_val


  let do_on_field fields index ~f =
    let open DSL.Syntax in
    let* index_q_opt = as_constant_q index in
    match index_q_opt with
    | None ->
        fresh ()
    | Some q -> (
        let* index_int =
          match QSafeCapped.to_int q with
          | None ->
              L.internal_error "bad index in iter_next_dict@\n" ;
              unreachable
          | Some i ->
              ret i
        in
        let* index_acc =
          match List.nth fields index_int with
          | None ->
              L.internal_error "iter next out of bounds@\n" ;
              unreachable
          | Some ia ->
              ret ia
        in
        match (index_acc : Access.t) with
        | FieldAccess fn ->
            f fn
        | _ ->
            L.internal_error "iter next dict non field access@\n" ;
            unreachable )


  let iter_get_key iter dict : unit DSL.model_monad =
    let open DSL.Syntax in
    let* fields = get_known_fields dict in
    let* index = load_access iter (FieldAccess index_field) in
    let* key = do_on_field fields index ~f:(fun fn -> make_hack_string (Fieldname.to_string fn)) in
    assign_ret key


  let iter_get_value iter dict : unit DSL.model_monad =
    let open DSL.Syntax in
    let* fields = get_known_fields dict in
    let* index = load_access iter (FieldAccess index_field) in
    let* value = do_on_field fields index ~f:(fun fn -> load_access dict (FieldAccess fn)) in
    assign_ret value


  let iter_next_dict iter dict : unit DSL.model_monad =
    let open DSL.Syntax in
    let* fields = get_known_fields dict in
    let* size_val = int (List.length fields) in
    let* index = load_access iter (FieldAccess index_field) in
    let* succindex = binop_int (PlusA None) index IntLit.one in
    (* In contrast to vecs, we don't have an overapproximate exit condition here *)
    let finished = prune_ge succindex size_val @@> make_hack_bool true in
    let not_finished =
      prune_lt succindex size_val
      @@> store_field ~ref:iter index_field succindex
      @@> make_hack_bool false
    in
    let* ret_val = disj [finished; not_finished] in
    assign_ret ret_val
end

let hack_add_elem_c this key value : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let default () =
    let* fresh = fresh () in
    assign_ret fresh
  in
  dynamic_dispatch this
    ~cases:[(TextualSil.hack_dict_type_name, fun () -> Dict.hack_add_elem_c_dsl this key value)]
    ~default


let hack_array_cow_set this args : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let default () =
    option_iter (List.last args) ~f:deep_clean_hack_value
    @@>
    let* fresh = fresh () in
    assign_ret fresh
  in
  dynamic_dispatch this
    ~cases:
      [ (Dict.type_name, fun () -> Dict.hack_array_cow_set_dsl this args)
      ; (Vec.type_name, fun () -> Vec.hack_array_cow_set_dsl this args) ]
    ~default


let hack_array_get this args : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let default () =
    L.d_warning "default case of hack_array_get" ;
    fresh ()
  in
  let hack_array_get_one_dim this key : DSL.aval DSL.model_monad =
    dynamic_dispatch this
      ~cases:
        [ (Dict.type_name, fun () -> Dict.hack_array_get_one_dim this key)
        ; (Vec.type_name, fun () -> Vec.hack_array_get_one_dim this key) ]
      ~default
  in
  let* value = list_fold args ~init:this ~f:hack_array_get_one_dim in
  let* value_with_taint = propagate_taint_attribute this value in
  assign_ret value_with_taint


let hack_array_idx this key default_val : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let default () =
    let* fresh = fresh () in
    assign_ret fresh
  in
  dynamic_dispatch this
    ~cases:
      [ (Dict.type_name, fun () -> Dict.hack_array_idx this key default_val)
      ; (Vec.type_name, fun () -> Vec.hack_array_idx this key default_val) ]
    ~default


let eval_resolved_field ~model_desc typ_name fld_str =
  let open DSL.Syntax in
  let* fld_opt, unresolved_reason = tenv_resolve_fieldname typ_name fld_str in
  let name, fld =
    match fld_opt with
    | None ->
        L.d_printfln_escaped "Could not resolve the field %a.%s" Typ.Name.pp typ_name fld_str ;
        (typ_name, Fieldname.make typ_name fld_str)
    | Some fld ->
        (Fieldname.get_class_name fld, fld)
  in
  let* class_object = get_static_companion_dsl ~model_desc name in
  (* Note: We avoid the MustBeInitialized attribute to be added when the field resolution is
     incomplete to avoid false positives. *)
  load_access ~no_access:(Option.is_some unresolved_reason) class_object (FieldAccess fld)


let internal_hack_field_get this field : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* opt_string_field_name = as_constant_string field in
  match opt_string_field_name with
  | Some string_field_name -> (
      let* opt_dynamic_type_data = get_dynamic_type ~ask_specialization:true this in
      match opt_dynamic_type_data with
      | Some {Formula.typ= {desc= Tstruct type_name}} ->
          let* aval =
            eval_resolved_field ~model_desc:"hack_field_get" type_name string_field_name
          in
          let* () =
            let field = Fieldname.make type_name string_field_name in
            let* struct_info = tenv_resolve_field_info type_name field in
            match struct_info with
            | Some {Struct.typ= field_typ} when Typ.is_pointer field_typ ->
                option_iter
                  (Typ.name (Typ.strip_ptr field_typ))
                  ~f:(fun field_type_name -> add_static_type field_type_name aval)
            | _ ->
                ret ()
          in
          ret aval
      | _ ->
          let field = TextualSil.wildcard_sil_fieldname Hack string_field_name in
          let* aval = load_access this (FieldAccess field) in
          ret aval )
  | None ->
      L.die InternalError "hack_field_get expect a string constant as 2nd argument"


let hack_field_get this field : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* retval = internal_hack_field_get this field in
  assign_ret retval


let make_hack_random_bool () : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* any = fresh () in
  let* boxed_bool = constructor hack_bool_type_name [("val", any)] in
  ret boxed_bool


let make_hack_unconstrained_int () : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* any = fresh () in
  let* boxed_int = constructor hack_int_type_name [("val", any)] in
  ret boxed_int


let hack_unconstrained_int : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* rv = make_hack_unconstrained_int () in
  assign_ret rv


let hhbc_not_dsl arg : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  (* this operator is always run on a HackBool argument (nonnull type) *)
  let* () = prune_ne_zero arg in
  let* int = load_access arg (FieldAccess bool_val_field) in
  zero_test_to_hack_bool int


let hhbc_not arg : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* res = hhbc_not_dsl arg in
  assign_ret res


let int_val_field = Fieldname.make hack_int_type_name "val"

let float_val_field = Fieldname.make hack_float_type_name "val"

let hhbc_cmp_same x y : model =
  L.d_printfln "hhbc_cmp_same(%a, %a)" AbstractValue.pp (fst x) AbstractValue.pp (fst y) ;
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let value_equality_test val1 val2 =
    let true_case = prune_eq val1 val2 @@> make_hack_bool true in
    let false_case = prune_ne val1 val2 @@> make_hack_bool false in
    disj [true_case; false_case]
  in
  let* res =
    disj
      [ prune_eq_zero x @@> prune_eq_zero y @@> make_hack_bool true
      ; prune_eq_zero x @@> prune_ne_zero y @@> make_hack_bool false
      ; prune_ne_zero x @@> prune_eq_zero y @@> make_hack_bool false
      ; ( prune_ne_zero x @@> prune_ne_zero y
        @@>
        let* x_dynamic_type_data = get_dynamic_type ~ask_specialization:true x in
        let* y_dynamic_type_data = get_dynamic_type ~ask_specialization:true y in
        match (x_dynamic_type_data, y_dynamic_type_data) with
        | ( Some {Formula.typ= {desc= Tstruct x_typ_name}}
          , Some {Formula.typ= {desc= Tstruct y_typ_name}} )
          when Typ.Name.equal x_typ_name y_typ_name ->
            L.d_printfln "hhbc_cmp_same: known dynamic type" ;
            if Typ.Name.equal x_typ_name hack_int_type_name then (
              L.d_printfln "hhbc_cmp_same: both are ints" ;
              let* x_val = load_access x (FieldAccess int_val_field) in
              let* y_val = load_access y (FieldAccess int_val_field) in
              value_equality_test x_val y_val )
            else if Typ.Name.equal x_typ_name hack_float_type_name then (
              L.d_printfln "hhbc_cmp_same: both are floats" ;
              let* x_val = load_access x (FieldAccess float_val_field) in
              let* y_val = load_access y (FieldAccess float_val_field) in
              value_equality_test x_val y_val )
            else if Typ.Name.equal x_typ_name hack_bool_type_name then (
              L.d_printfln "hhbc_cmp_same: both are bools" ;
              let* x_val = load_access x (FieldAccess bool_val_field) in
              let* y_val = load_access y (FieldAccess bool_val_field) in
              value_equality_test x_val y_val )
            else if Typ.Name.equal x_typ_name hack_string_type_name then (
              L.d_printfln "hhbc_cmp_same: both are strings" ;
              let* x_val = load_access x (FieldAccess string_val_field) in
              let* y_val = load_access y (FieldAccess string_val_field) in
              disj
                [ prune_eq x_val y_val @@> make_hack_bool true
                ; prune_ne x_val y_val @@> make_hack_bool false ] )
            else (
              L.d_printfln "hhbc_cmp_same: not a known primitive type" ;
              disj
                [ prune_eq x y
                  @@> (* CAUTION: Note that the pruning on a pointer may result in incorrect semantics
                         if the pointer is given as a parameter. In that case, the pruning may work as
                         a value assignment to the pointer. *)
                  make_hack_bool true
                ; prune_ne x y
                  @@> (* TODO(dpichardie) cover the comparisons of vec, keyset, dict and
                         shape, taking into account the difference between == and ===. *)
                      (* TODO(dpichardie) cover the specificities of == that compare objects properties
                         (structural equality). *)
                  make_hack_random_bool () ] )
        | Some {Formula.typ= x_typ}, Some {Formula.typ= y_typ} when not (Typ.equal x_typ y_typ) ->
            L.d_printfln "hhbc_cmp_same: known different dynamic types: false result" ;
            make_hack_bool false
        | _ ->
            L.d_printfln "hhbc_cmp_same: at least one unknown dynamic type: unknown result" ;
            make_hack_random_bool () ) ]
  in
  assign_ret res


let hack_is_true b : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let nullcase =
    prune_eq_zero b
    @@>
    let* zero = int 0 in
    assign_ret zero
  in
  let nonnullcase =
    prune_ne_zero b
    @@>
    let* b_dynamic_type_data = get_dynamic_type ~ask_specialization:true b in
    match b_dynamic_type_data with
    | None ->
        let* ret = make_hack_random_bool () in
        assign_ret ret
    | Some {Formula.typ= {Typ.desc= Tstruct b_typ_name}} ->
        if Typ.Name.equal b_typ_name hack_bool_type_name then
          let* b_val = load_access b (FieldAccess bool_val_field) in
          assign_ret b_val
        else (
          L.d_printfln "istrue got typename %a" Typ.Name.pp b_typ_name ;
          let* one = int 1 in
          assign_ret one )
    | _ ->
        unreachable (* shouldn't happen *)
  in
  disj [nullcase; nonnullcase]


let hhbc_cmp_nsame x y : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* bool = lift_to_monad_and_get_result (hhbc_cmp_same x y) in
  let* neg_bool = hhbc_not_dsl bool in
  assign_ret neg_bool


let hhbc_cls_cns this field : model =
  let model_desc = "hhbc_cls_cns" in
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* dynamic_Type_data_opt = get_dynamic_type ~ask_specialization:true this in
  let* field_v =
    match dynamic_Type_data_opt with
    | Some {Formula.typ= {Typ.desc= Tstruct name}} ->
        let* opt_string_field_name = read_string_value_dsl field in
        let string_field_name =
          match opt_string_field_name with
          | Some str ->
              str
          | None ->
              (* we do not expect this situation to happen because hhbc_cls_cns takes as argument
                 a literal string see:
                 https://github.com/facebook/hhvm/blob/master/hphp/doc/bytecode.specification *)
              L.internal_error "hhbc_cls_cns has been called on non-constant string@\n" ;
              "__dummy_constant_name__"
        in
        eval_resolved_field ~model_desc name string_field_name
    | _ ->
        fresh ()
  in
  assign_ret field_v


let hack_get_class this : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* typ_opt = get_dynamic_type ~ask_specialization:true this in
  let* field_v = match typ_opt with Some _ -> ret this | None -> fresh () in
  assign_ret field_v


(* we don't have a different kind of lazy class objects, so this is the identity, but maybe we should force initialization here? *)
let hhbc_lazy_class_from_class this : model =
  let open DSL.Syntax in
  start_model @@ fun () -> assign_ret this


(* HH::type_structure should officially be able to take an instance of a class or the name (classname=string) as first argument, and
   null or the name of a type constant as second argument
   See https://github.com/facebook/hhvm/blob/master/hphp/runtime/ext/reflection/ext_reflection-classes.php
   However, to start with we just deal with the case that the first argument is one of our static companion objects
   and the second is a type constant name
   If the static companion has been _86constinit'd then this should just be a field dereference
*)
let hh_type_structure clsobj constnameobj : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* constname = load_access constnameobj (FieldAccess string_val_field) in
  constinit_existing_class_object clsobj
  @@>
  let* retval = internal_hack_field_get clsobj constname in
  assign_ret retval


let hack_set_static_prop this prop obj : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* opt_this = read_string_value_dsl this in
  let* opt_prop = read_string_value_dsl prop in
  match (opt_this, opt_prop) with
  | Some this, Some prop ->
      let this = replace_backslash_with_colon this in
      let name = Typ.HackClass (HackClassName.static_companion (HackClassName.make this)) in
      let* class_object = get_static_companion_dsl ~model_desc:"hack_set_static_prop" name in
      store_field ~ref:class_object (Fieldname.make name prop) obj
  | _, _ ->
      ret ()


let hhbc_cmp_lt x y : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let value_lt_test val1 val2 =
    let true_case = prune_lt val1 val2 @@> make_hack_bool true in
    let false_case = prune_ge val1 val2 @@> make_hack_bool false in
    disj [true_case; false_case]
  in
  let* res =
    disj
      [ prune_eq x y @@> make_hack_bool false
      ; prune_ne x y
        @@> disj
              [ (* either of those is null but not both *)
                disj [prune_eq_zero x; prune_eq_zero y]
                @@> make_hack_bool false (* should throw error/can't happen *)
              ; ( prune_ne_zero x @@> prune_ne_zero y
                @@>
                let* x_dynamic_type_data = get_dynamic_type ~ask_specialization:true x in
                let* y_dynamic_type_data = get_dynamic_type ~ask_specialization:true y in
                match (x_dynamic_type_data, y_dynamic_type_data) with
                | None, _ | _, None ->
                    L.d_printfln "random nones" ;
                    make_hack_random_bool ()
                | ( Some {Formula.typ= {Typ.desc= Tstruct x_typ_name}}
                  , Some {Formula.typ= {Typ.desc= Tstruct y_typ_name}} )
                  when Typ.Name.equal x_typ_name y_typ_name ->
                    if Typ.Name.equal x_typ_name hack_int_type_name then
                      let* x_val = load_access x (FieldAccess int_val_field) in
                      let* y_val = load_access y (FieldAccess int_val_field) in
                      value_lt_test x_val y_val
                    else if Typ.Name.equal x_typ_name hack_float_type_name then
                      let* x_val = load_access x (FieldAccess float_val_field) in
                      let* y_val = load_access y (FieldAccess float_val_field) in
                      value_lt_test x_val y_val
                    else if Typ.Name.equal x_typ_name hack_bool_type_name then
                      let* x_val = load_access x (FieldAccess bool_val_field) in
                      let* y_val = load_access y (FieldAccess bool_val_field) in
                      value_lt_test x_val y_val
                    else (
                      L.d_printfln "random somes" ;
                      make_hack_random_bool () )
                | _, _ ->
                    make_hack_bool false ) ] ]
  in
  assign_ret res


let hhbc_cmp_gt x y : model = hhbc_cmp_lt y x

let hhbc_cmp_le x y : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let value_le_test val1 val2 =
    let true_case = prune_le val1 val2 @@> make_hack_bool true in
    let false_case = prune_gt val1 val2 @@> make_hack_bool false in
    disj [true_case; false_case]
  in
  let* res =
    disj
      [ prune_eq x y @@> make_hack_bool true
      ; prune_ne x y
        @@> disj
              [ (* either of those is null but not both *)
                disj [prune_eq_zero x; prune_eq_zero y]
                @@> make_hack_bool false (* should throw error/can't happen *)
              ; ( prune_ne_zero x @@> prune_ne_zero y
                @@>
                let* x_dynamic_type_data = get_dynamic_type ~ask_specialization:true x in
                let* y_dynamic_type_data = get_dynamic_type ~ask_specialization:true y in
                match (x_dynamic_type_data, y_dynamic_type_data) with
                | None, _ | _, None ->
                    make_hack_random_bool ()
                | ( Some {Formula.typ= {Typ.desc= Tstruct x_typ_name}}
                  , Some {Formula.typ= {Typ.desc= Tstruct y_typ_name}} )
                  when Typ.Name.equal x_typ_name y_typ_name ->
                    if Typ.Name.equal x_typ_name hack_int_type_name then
                      let* x_val = load_access x (FieldAccess int_val_field) in
                      let* y_val = load_access y (FieldAccess int_val_field) in
                      value_le_test x_val y_val
                    else if Typ.Name.equal x_typ_name hack_float_type_name then
                      let* x_val = load_access x (FieldAccess float_val_field) in
                      let* y_val = load_access y (FieldAccess float_val_field) in
                      value_le_test x_val y_val
                    else if Typ.Name.equal x_typ_name hack_bool_type_name then
                      let* x_val = load_access x (FieldAccess bool_val_field) in
                      let* y_val = load_access y (FieldAccess bool_val_field) in
                      value_le_test x_val y_val
                    else make_hack_random_bool ()
                | _, _ ->
                    make_hack_bool false ) ] ]
  in
  assign_ret res


let hhbc_cmp_ge x y : model = hhbc_cmp_le y x

let hhbc_add x y : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* x_dynamic_type_data = get_dynamic_type ~ask_specialization:true x in
  let* y_dynamic_type_data = get_dynamic_type ~ask_specialization:true y in
  match (x_dynamic_type_data, y_dynamic_type_data) with
  | ( Some {Formula.typ= {Typ.desc= Tstruct x_typ_name}}
    , Some {Formula.typ= {Typ.desc= Tstruct y_typ_name}} )
    when Typ.Name.equal x_typ_name y_typ_name && Typ.Name.equal x_typ_name hack_int_type_name ->
      let* x_val = load_access x (FieldAccess int_val_field) in
      let* y_val = load_access y (FieldAccess int_val_field) in
      let* sum = binop (PlusA (Some IInt)) x_val y_val in
      let* res = aval_to_hack_int sum in
      assign_ret res
  | _, _ ->
      let* sum = fresh () in
      assign_ret sum (* unconstrained value *)


let hhbc_iter_base arg : model =
  let open DSL.Syntax in
  start_model @@ fun () -> assign_ret arg


let hhbc_iter_init iter obj : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  dynamic_dispatch obj
    ~cases:
      [ (Dict.type_name, fun () -> DictIter.iter_init_dict iter obj)
      ; (Vec.type_name, fun () -> VecIter.iter_init_vec iter obj) ]
      (* TODO: The default is a hack to make the variadic.hack test work, should be fixed properly *)
    ~default:(fun () -> VecIter.iter_init_vec iter obj)


let hhbc_iter_get_key iter obj : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  dynamic_dispatch obj
    ~cases:
      [ (Dict.type_name, fun () -> DictIter.iter_get_key iter obj)
      ; (Vec.type_name, fun () -> VecIter.iter_get_key iter obj) ]
      (* TODO: The default is a hack to make the variadic.hack test work, should be fixed properly *)
    ~default:(fun () -> VecIter.iter_get_key iter obj)


let hhbc_iter_get_value iter obj : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  dynamic_dispatch obj
    ~cases:
      [ (Dict.type_name, fun () -> DictIter.iter_get_value iter obj)
      ; (Vec.type_name, fun () -> VecIter.iter_get_value iter obj) ]
      (* TODO: The default is a hack to make the variadic.hack test work, should be fixed properly *)
    ~default:(fun () -> VecIter.iter_get_value iter obj)


let hhbc_iter_next iter obj : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  dynamic_dispatch obj
    ~cases:
      [ (Dict.type_name, fun () -> DictIter.iter_next_dict iter obj)
      ; (Vec.type_name, fun () -> VecIter.iter_next_vec iter obj) ]
      (* TODO: The default is a hack to make the variadic.hack test work, should be fixed properly *)
    ~default:(fun () -> VecIter.iter_next_vec iter obj)


let hack_throw : model =
  let open DSL.Syntax in
  start_model @@ fun () -> throw


module SplatedVec = struct
  let type_name = TextualSil.hack_splated_vec_type_name

  let field_name = "content"

  let field = Fieldname.make type_name field_name

  let make arg : model =
    let open DSL.Syntax in
    start_model
    @@ fun () ->
    let* boxed = constructor type_name [(field_name, arg)] in
    assign_ret boxed


  let build_vec_for_variadic_callee args : DSL.aval DSL.model_monad =
    let open DSL.Syntax in
    match args with
    | [arg] -> (
        let* arg_dynamic_type_data = get_dynamic_type ~ask_specialization:false arg in
        match arg_dynamic_type_data with
        | Some {Formula.typ= {Typ.desc= Tstruct name}} when Typ.Name.equal name type_name ->
            load_access arg (FieldAccess field)
        | _ ->
            Vec.new_vec_dsl args )
    | _ ->
        Vec.new_vec_dsl args
end

let build_vec_for_variadic_callee data args astate =
  let reason () =
    F.asprintf "error when executing build_vec_for_variadic_callee [%a]"
      (Pp.seq ~sep:"," AbstractValue.pp)
      (List.map args ~f:fst)
  in
  ( SplatedVec.build_vec_for_variadic_callee args
  |> DSL.unsafe_to_astate_transformer {reason; source= __POS__} )
    (Model "variadic args vec", data) astate


(* Map the kind tag values used in type structure dictionaries to their corresponding Pulse dynamic type names
   This only decodes primitive types
   See https://github.com/facebook/hhvm/blob/master/hphp/runtime/base/type-structure-kinds.h
*)
let type_struct_prim_tag_to_classname n =
  match n with
  | 0 ->
      None (* void doesn't have a tag 'cos it's represented as null *)
  | 1 ->
      Some hack_int_type_name
  | 2 ->
      Some hack_bool_type_name
  | 3 ->
      Some hack_float_type_name
  | 4 ->
      Some hack_string_type_name
  | 14 ->
      Some Dict.type_name (* really shape but the reps should be the same *)
  | 19 ->
      Some Dict.type_name (* actually dict this time *)
  | 20 ->
      Some Vec.type_name
  | _ ->
      None


let read_nullable_field_from_ts tdict =
  let open DSL.Syntax in
  let nullable_field = TextualSil.wildcard_sil_fieldname Textual.Lang.Hack "nullable" in
  let* nullable_boxed_bool = load_access tdict (FieldAccess nullable_field) in
  let* nullable_bool_val = load_access nullable_boxed_bool (FieldAccess bool_val_field) in
  as_constant_bool nullable_bool_val


let read_string_field_from_ts fieldname tdict =
  let open DSL.Syntax in
  let field = TextualSil.wildcard_sil_fieldname Textual.Lang.Hack fieldname in
  let* field_boxed_string = load_access tdict (FieldAccess field) in
  let* field_string_val = load_access field_boxed_string (FieldAccess string_val_field) in
  as_constant_string field_string_val


let read_access_from_ts tdict =
  let open DSL.Syntax in
  let field = TextualSil.wildcard_sil_fieldname Textual.Lang.Hack "access_list" in
  let* access_list_vec = load_access tdict (FieldAccess field) in
  (* TODO: this should work for an access list of length one, but will not for more accesses
     (which we get for source like C::T1::T2) because
      vec_get_dsl actually ignores its index :-( To fix, we either have to change the way we deal with
      vectors to be more precise (at least for smallish constant vecs) or tweak the encoding
      of type structures for Infer to use something different (less faithful to HHVM) *)
  let* type_prop_name_boxed_string = Vec.get_vec_dsl access_list_vec 0 in
  let* type_prop_name_string_val =
    load_access type_prop_name_boxed_string (FieldAccess string_val_field)
  in
  as_constant_string type_prop_name_string_val


(* returns a fresh value equated to the SIL result of the comparison *)
let check_against_type_struct v tdict : DSL.aval DSL.model_monad =
  let open DSL.Syntax in
  let* inner_val = fresh () in
  let rec find_name tdict nullable_already visited_set =
    let kind_field = TextualSil.wildcard_sil_fieldname Textual.Lang.Hack "kind" in
    let* kind_boxed_int = load_access tdict (FieldAccess kind_field) in
    let* kind_int_val = load_access kind_boxed_int (FieldAccess int_val_field) in
    let* kind_int_opt = as_constant_int kind_int_val in
    match kind_int_opt with
    | None ->
        L.d_printfln "didn't get known integer tag in check against type struct" ;
        let* md = get_data in
        L.d_printfln "known tag failure tdict is %a at %a" AbstractValue.pp (fst tdict)
          Location.pp_file_pos md.location ;
        ret None
    | Some k -> (
        let* nullable_bool_opt = read_nullable_field_from_ts tdict in
        let nullable = nullable_already || Option.value nullable_bool_opt ~default:false in
        match type_struct_prim_tag_to_classname k with
        | Some name ->
            ret (Some (name, nullable))
        | None ->
            if Int.(k = 101) then
              (* 101 is the magic number for "Unresolved type" in type structures.
                 See https://github.com/facebook/hhvm/blob/master/hphp/runtime/base/type-structure-kinds.h *)
              let* classname_string_opt = read_string_field_from_ts "classname" tdict in
              ret
                (Option.map classname_string_opt ~f:(fun s ->
                     (Typ.HackClass (HackClassName.make (replace_backslash_with_colon s)), nullable) )
                )
            else if Int.(k = 102) then (
              (* 102 is the magic number for type access *)
              L.d_printfln "testing against type access" ;
              let* rootname_opt = read_string_field_from_ts "root_name" tdict in
              let* type_prop_name_opt = read_access_from_ts tdict in
              match (rootname_opt, type_prop_name_opt) with
              | Some rootname, Some type_prop_name ->
                  let rootname = replace_backslash_with_colon rootname in
                  L.d_printfln "got root_name = %s, type_prop_name = %s" rootname type_prop_name ;
                  let concatenated_name = Printf.sprintf "%s$$%s" rootname type_prop_name in
                  if IString.Set.mem concatenated_name visited_set then (
                    L.d_printfln "Cyclic type constant detected!" ;
                    ret None )
                  else
                    let type_prop_field = TextualSil.wildcard_sil_fieldname Hack type_prop_name in
                    let* companion =
                      get_initialized_class_object (HackClass (HackClassName.make rootname))
                    in
                    L.d_printfln "companion object is %a" AbstractValue.pp (fst companion) ;
                    let* type_constant_ts = load_access companion (FieldAccess type_prop_field) in
                    (* We've got another type structure in our hands now, so recurse *)
                    L.d_printfln "type structure for projection=%a" AbstractValue.pp
                      (fst type_constant_ts) ;
                    find_name type_constant_ts nullable
                      (IString.Set.add concatenated_name visited_set)
              | _, _ ->
                  ret None )
            else ret None )
  in
  let* name_opt = find_name tdict false IString.Set.empty in
  match name_opt with
  | Some (name, nullable) ->
      L.d_printfln "type structure test against type name %a" Typ.Name.pp name ;
      let typ = Typ.mk (Typ.Tstruct name) in
      and_equal_instanceof inner_val v typ ~nullable @@> ret inner_val
  | None ->
      ret inner_val


(* for now ignores resolve and enforce options *)
let hhbc_is_type_struct_c v tdict _resolveop _enforcekind : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* inner_val = check_against_type_struct v tdict in
  let* wrapped_result = aval_to_hack_bool inner_val in
  assign_ret wrapped_result


let hhbc_verify_param_type_ts v tdict : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* inner_val = check_against_type_struct v tdict in
  prune_ne_zero inner_val
  @@>
  let* zero = int 0 in
  assign_ret zero


let hhbc_is_type_prim typname v : model =
  let open DSL.Syntax in
  let model_desc = Printf.sprintf "hhbc_is_type_%s" (Typ.Name.to_string typname) in
  start_named_model model_desc
  @@ fun () ->
  let typ = Typ.mk (Typ.Tstruct typname) in
  let* inner_val = fresh () in
  let* rv = aval_to_hack_bool inner_val in
  and_equal_instanceof inner_val v typ ~nullable:false @@> assign_ret rv


let hhbc_is_type_str = hhbc_is_type_prim hack_string_type_name

let hhbc_is_type_bool = hhbc_is_type_prim hack_bool_type_name

let hhbc_is_type_int = hhbc_is_type_prim hack_int_type_name

let hhbc_is_type_float = hhbc_is_type_prim hack_float_type_name

let hhbc_is_type_dict = hhbc_is_type_prim Dict.type_name

let hhbc_is_type_vec = hhbc_is_type_prim Vec.type_name

let hhbc_verify_type_pred _dummy pred : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* pred_val = load_access pred (FieldAccess bool_val_field) in
  prune_ne_zero pred_val
  @@>
  (* TODO: log when state is unsat at this point *)
  let* zero = int 0 in
  assign_ret zero


let hhbc_cast_string arg : model =
  (* https://github.com/facebook/hhvm/blob/605ac5dde604ded7f25e9786032a904f28230845/hphp/doc/bytecode.specification#L1087
     Cast to string ((string),(binary)). Pushes (string)$1 onto the stack. If $1
     is an object that implements the __toString method, the string cast returns
     $1->__toString(). If $1 is an object that does not implement __toString
     method, the string cast throws a fatal error.
  *)
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* dynamic_type_data = get_dynamic_type ~ask_specialization:true arg in
  let* res =
    match dynamic_type_data with
    | Some {Formula.typ= {Typ.desc= Tstruct typ_name}}
      when Typ.Name.equal typ_name hack_string_type_name ->
        ret arg
    | Some _ ->
        (* note: we do not model precisely the value returned by __toString() *)
        make_hack_string "__infer_hack_generated_from_cast_string"
        (* note: we do not model the case where __toString() is not implemented *)
    | _ ->
        (* hopefully we will come back later with a dynamic type thanks to specialization *)
        fresh ()
  in
  let source_addr, source_hist = arg in
  let dest_addr, _ = res in
  let taints_attr = [Attribute.{v= source_addr; history= source_hist}] in
  let* () =
    AbductiveDomain.AddressAttributes.add_one dest_addr
      (PropagateTaintFrom (InternalModel, taints_attr))
    |> exec_command
  in
  assign_ret res


let hhbc_concat arg1 arg2 : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* arg1_val = load_access arg1 (FieldAccess string_val_field) in
  let* arg2_val = load_access arg2 (FieldAccess string_val_field) in
  let* res = string_concat arg1_val arg2_val in
  let* res = hack_string_dsl res in
  assign_ret res


let hack_enum_label : model =
  let open DSL.Syntax in
  start_model
  @@ fun () ->
  let* any = fresh () in
  assign_ret any


let matchers : matcher list =
  let open ProcnameDispatcher.Call in
  [ -"$builtins" &:: "nondet" <>$$--> lift_model @@ Basic.nondet ~desc:"nondet"
  ; +BuiltinDecl.(match_builtin __lazy_class_initialize) <>$ capt_exp $--> lazy_class_initialize
  ; +BuiltinDecl.(match_builtin __get_lazy_class) <>$ capt_exp $--> lazy_class_initialize
  ; +BuiltinDecl.(match_builtin __hack_throw) <>--> hack_throw
  ; -"$builtins" &:: "hack_string" <>$ capt_arg_payload $--> hack_string
  ; -"$builtins" &:: "__sil_splat" <>$ capt_arg_payload $--> SplatedVec.make
  ; -"$builtins" &:: "hhbc_add_elem_c" <>$ capt_arg_payload $+ capt_arg_payload $+ capt_arg_payload
    $--> hack_add_elem_c
  ; -"$builtins" &:: "hhbc_await" <>$ capt_arg_payload $--> hack_await
  ; -"$builtins" &:: "hack_array_get" <>$ capt_arg_payload $+++$--> hack_array_get
  ; -"$builtins" &:: "hhbc_idx" <>$ capt_arg_payload $+ capt_arg_payload $+ capt_arg_payload
    $--> hack_array_idx
  ; -"$builtins" &:: "hack_array_cow_set" <>$ capt_arg_payload $+++$--> hack_array_cow_set
  ; -"$builtins" &:: "hack_new_dict" &::.*+++> Dict.new_dict
  ; -"$builtins" &:: "hhbc_new_dict" &::.*+++> Dict.new_dict
  ; -"$builtins" &:: "hhbc_new_vec" &::.*+++> Vec.new_vec
  ; -"$builtins" &:: "hhbc_not" <>$ capt_arg_payload $--> hhbc_not
  ; -"$builtins" &:: "hack_get_class" <>$ capt_arg_payload $--> hack_get_class
  ; -"$builtins" &:: "hhbc_lazy_class_from_class" <>$ capt_arg_payload
    $--> hhbc_lazy_class_from_class
  ; -"$builtins" &:: "hack_field_get" <>$ capt_arg_payload $+ capt_arg_payload $--> hack_field_get
  ; -"$builtins" &:: "hhbc_cast_string" <>$ capt_arg_payload $--> hhbc_cast_string
  ; -"$builtins" &:: "hhbc_class_get_c" <>$ capt_arg_payload $--> hhbc_class_get_c
    (* we should be able to model that directly in Textual once specialization will be stronger *)
  ; -"$builtins" &:: "hhbc_cmp_same" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_same
  ; -"$builtins" &:: "hhbc_cmp_nsame" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_nsame
  ; -"$builtins" &:: "hhbc_cmp_eq" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_same
  ; -"$builtins" &:: "hhbc_cmp_neq" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_nsame
  ; -"$builtins" &:: "hhbc_cmp_lt" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_lt
  ; -"$builtins" &:: "hhbc_cmp_gt" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_gt
  ; -"$builtins" &:: "hhbc_cmp_ge" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_ge
  ; -"$builtins" &:: "hhbc_concat" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_concat
  ; -"$builtins" &:: "hhbc_cmp_le" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cmp_le
  ; -"$builtins" &:: "hack_is_true" <>$ capt_arg_payload $--> hack_is_true
  ; -"$builtins" &:: "hhbc_is_type_null" <>$ capt_arg_payload $--> hhbc_is_type_null
  ; -"$builtins" &:: "hhbc_is_type_str" <>$ capt_arg_payload $--> hhbc_is_type_str
  ; -"$builtins" &:: "hhbc_is_type_bool" <>$ capt_arg_payload $--> hhbc_is_type_bool
  ; -"$builtins" &:: "hhbc_is_type_int" <>$ capt_arg_payload $--> hhbc_is_type_int
  ; -"$builtins" &:: "hhbc_is_type_dbl" <>$ capt_arg_payload $--> hhbc_is_type_float
  ; -"$builtins" &:: "hhbc_is_type_dict" <>$ capt_arg_payload $--> hhbc_is_type_dict
  ; -"$builtins" &:: "hhbc_is_type_vec" <>$ capt_arg_payload $--> hhbc_is_type_vec
  ; -"$builtins" &:: "hhbc_verify_type_pred" <>$ capt_arg_payload $+ capt_arg_payload
    $--> hhbc_verify_type_pred
  ; -"$builtins" &:: "hhbc_verify_param_type_ts" <>$ capt_arg_payload $+ capt_arg_payload
    $--> hhbc_verify_param_type_ts
  ; -"$builtins" &:: "hhbc_add" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_add
  ; -"$builtins" &:: "hack_get_static_class" <>$ capt_arg_payload $--> get_static_class
  ; -"$builtins" &:: "hhbc_cls_cns" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_cls_cns
  ; -"$builtins" &:: "hack_set_static_prop" <>$ capt_arg_payload $+ capt_arg_payload
    $+ capt_arg_payload $--> hack_set_static_prop
  ; -"$builtins" &:: "hhbc_is_type_struct_c" <>$ capt_arg_payload $+ capt_arg_payload
    $+ capt_arg_payload $+ capt_arg_payload $--> hhbc_is_type_struct_c
  ; -"$root" &:: "FlibSL::C::contains_key" <>$ any_arg $+ capt_arg_payload $+ capt_arg_payload
    $--> Dict.contains_key
  ; -"$root" &:: "FlibSL::Vec::map" <>$ capt_arg_payload $+ capt_arg_payload $+ capt_arg_payload
    $--> Vec.map
  ; -"$root" &:: "FlibSL::Vec::from_async" <>$ capt_arg_payload $+ capt_arg_payload
    $--> Vec.vec_from_async
  ; -"$root" &:: "FlibSL::Dict::from_async" <>$ capt_arg_payload $+ capt_arg_payload
    $--> Dict.dict_from_async
  ; -"Asio$static" &:: "awaitSynchronously" <>$ capt_arg_payload $+ capt_arg_payload
    $--> hack_await_static
  ; -"$root" &:: "HH::type_structure" <>$ any_arg $+ capt_arg_payload $+ capt_arg_payload
    $--> hh_type_structure
  ; -"$builtins" &:: "hhbc_iter_base" <>$ capt_arg_payload $--> hhbc_iter_base
  ; -"$builtins" &:: "hhbc_iter_init" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_iter_init
  ; -"$builtins" &:: "hhbc_iter_get_key" <>$ capt_arg_payload $+ capt_arg_payload
    $--> hhbc_iter_get_key
  ; -"$builtins" &:: "hhbc_iter_get_value" <>$ capt_arg_payload $+ capt_arg_payload
    $--> hhbc_iter_get_value
  ; -"$builtins" &:: "hhbc_iter_next" <>$ capt_arg_payload $+ capt_arg_payload $--> hhbc_iter_next
  ; -"$builtins" &:: "hack_enum_label" <>--> hack_enum_label
  ; -"Infer$static" &:: "newUnconstrainedInt" <>$ any_arg $--> hack_unconstrained_int ]
  |> List.map ~f:(ProcnameDispatcher.Call.contramap_arg_payload ~f:ValueOrigin.addr_hist)
