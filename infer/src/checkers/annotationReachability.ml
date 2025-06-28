(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging
module MF = MarkupFormatter
module Domain = AnnotationReachabilityDomain

let annotation_of_str annot_str = {Annot.class_name= annot_str; parameters= []}

let dummy_constructor_annot = annotation_of_str "__infer_is_constructor"

let is_dummy_constructor annot =
  String.equal annot.Annot.class_name dummy_constructor_annot.class_name


let dummy_field_method_prefix = "__infer_field_"

let is_dummy_field_pname pname =
  String.is_prefix ~prefix:dummy_field_method_prefix (Procname.get_method pname)


let dummy_pname_for_field fieldname typ =
  (* This assumes Java and can result in errors for other languages, e.g.
     typ can be a pointer. Plus putting a non-Java type in Procname.make_java
     can cause problems later. *)
  let class_name = Option.value_exn (Typ.name typ) in
  Procname.make_java ~class_name ~return_type:None
    ~method_name:(dummy_field_method_prefix ^ Fieldname.get_field_name fieldname)
    ~parameters:[] ~kind:Non_Static


let classname_from_dummy_pname pname = Option.value_exn (Procname.get_class_type_name pname)

let fieldname_from_dummy_pname pname =
  let classname = classname_from_dummy_pname pname in
  let field_name =
    String.chop_prefix_if_exists ~prefix:dummy_field_method_prefix (Procname.get_method pname)
  in
  Fieldname.make classname field_name


let struct_from_dummy_pname tenv pname =
  Option.value_exn (Tenv.lookup tenv (classname_from_dummy_pname pname))


let is_modeled_expensive tenv = function
  | Procname.Java proc_name_java as proc_name ->
      (not (BuiltinDecl.is_declared proc_name))
      &&
      let is_subclass =
        let classname = Procname.Java.get_class_type_name proc_name_java in
        PatternMatch.is_subtype_of_str tenv classname
      in
      Inferconfig.modeled_expensive_matcher is_subclass proc_name
  | _ ->
      false


let is_allocator tenv pname =
  match pname with
  | Procname.Java pname_java ->
      let is_throwable () =
        let class_name = Procname.Java.get_class_type_name pname_java in
        PatternMatch.Java.is_throwable tenv class_name
      in
      Procname.is_constructor pname
      && (not (BuiltinDecl.is_declared pname))
      && not (is_throwable ())
  | _ ->
      false


type custom_model = {method_regex: string; annotation: string} [@@deriving of_yojson]

type custom_models = custom_model list [@@deriving of_yojson]

let parse_custom_models () =
  match Config.annotation_reachability_custom_models with
  (* The default value for JSON options is an empty list and not an empty object *)
  | `List [] ->
      IString.Map.empty
  | json ->
      json |> Yojson.Safe.Util.to_assoc
      |> List.map ~f:(fun (key, val_arr) ->
             ( key
             , val_arr |> Yojson.Safe.Util.to_list
               |> List.map ~f:Yojson.Safe.Util.to_string
               |> List.map ~f:Str.regexp ) )
      |> Stdlib.List.to_seq |> IString.Map.of_seq


let check_attributes check tenv pname =
  match pname with
  | Procname.Java _ ->
      let proc_has_attribute = Annotations.pname_has_return_annot pname check in
      let class_has_attribute =
        ( if Config.annotation_reachability_apply_superclass_annotations then
            PatternMatch.Java.check_class_attributes
          else PatternMatch.Java.check_current_class_attributes )
          check tenv pname
      in
      class_has_attribute || proc_has_attribute
  | _ ->
      false


let check_modeled_annotation models annot pname =
  let method_name =
    Procname.to_string ~verbosity:(if Procname.is_erlang pname then Verbose else FullNameOnly) pname
  in
  Option.exists (IString.Map.find_opt annot.Annot.class_name models) ~f:(fun methods ->
      List.exists methods ~f:(fun r -> Str.string_match r method_name 0) )


let find_override_with_annot annot models tenv pname =
  let has_annot ia = Annotations.ia_ends_with ia annot.Annot.class_name in
  if is_dummy_field_pname pname then
    (* Get back the original field from the fake call *)
    let struct_typ = struct_from_dummy_pname tenv pname in
    let fieldname = fieldname_from_dummy_pname pname in
    if Annotations.field_has_annot fieldname struct_typ has_annot then Some pname else None
  else
    let method_has_annot pname =
      if Config.annotation_reachability_no_allocation && is_dummy_constructor annot then
        is_allocator tenv pname
      else if
        Config.annotation_reachability_expensive
        && Annotations.annot_ends_with annot Annotations.expensive
      then check_attributes has_annot tenv pname || is_modeled_expensive tenv pname
      else check_attributes has_annot tenv pname || check_modeled_annotation models annot pname
    in
    PatternMatch.override_find method_has_annot tenv pname


let method_overrides_annot annot models tenv pname =
  find_override_with_annot annot models tenv pname |> Option.is_some


let lookup_annotation_calls {InterproceduralAnalysis.analyze_dependency} annot pname =
  analyze_dependency pname |> AnalysisResult.to_option
  |> Option.bind ~f:(Domain.find_opt annot)
  |> Option.value ~default:Domain.SinkMap.empty


let str_of_pname ?(withclass = false) ?(full = false) pname =
  if is_dummy_field_pname pname then
    (* Get back the original field from the fake call *)
    let fieldname = fieldname_from_dummy_pname pname in
    if withclass then Fieldname.to_simplified_string fieldname
    else Fieldname.get_field_name fieldname
  else if full then F.asprintf "%a" Procname.pp_fullname_only pname
  else Procname.to_simplified_string ~withclass pname


module AnnotationSpec = struct
  type predicate = Tenv.t -> Procname.t -> bool

  type t =
    { kind: string  (** for debugging *)
    ; sink_predicate: predicate  (** decide if something is a sink *)
    ; sanitizer_predicate: predicate  (** decide if something is a sanitizer *)
    ; sink_annotation: Annot.t  (** used as key in the domain (sink -> procedure -> callsite) *)
    ; source_annotation_list: Annot.t list  (** decide if something is a source *)
    ; name: string  (** Short name to be added at the beginning of the report *)
    ; description: string  (** Extra description to be added to the issue report *)
    ; issue_type: IssueType.t
    ; models: Str.regexp list IString.Map.t  (** model functions as if they were annotated *)
    ; pre_check: Domain.t InterproceduralAnalysis.t -> unit
          (** additional check before reporting *) }
end

let prepend_if_not_empty str prefix = if String.equal str "" then "" else prefix ^ str

let append_if_not_empty str suffix = if String.equal str "" then "" else str ^ suffix

let report_src_to_snk_path {InterproceduralAnalysis.proc_desc; tenv; err_log} src
    (spec : AnnotationSpec.t) loc trace snk_pname =
  let get_original_pname annot pname =
    find_override_with_annot annot spec.models tenv pname |> Option.value ~default:pname
  in
  (* Check if the annotation is inherited from a base class method. *)
  let get_details annot pname =
    let origin_pname = get_original_pname annot pname in
    if Procname.equal origin_pname pname then ""
    else
      Format.asprintf ", inherited from %a" MF.pp_monospaced
        (str_of_pname ~withclass:true origin_pname)
  in
  (* Check if the annotation is inherited from a base class/interface. *)
  let get_class_details annot pname =
    let has_annot ia = Annotations.ia_ends_with ia annot.Annot.class_name in
    let pname = get_original_pname annot pname in
    match Procname.get_class_type_name pname with
    | Some typ -> (
      match PatternMatch.Java.find_superclasses_with_attributes has_annot tenv typ with
      | [] ->
          ""
      | types ->
          let typ_to_str t =
            Option.map
              ~f:(fun name -> Format.asprintf "%a" MF.pp_monospaced (JavaClassName.classname name))
              (Typ.Name.Java.get_java_class_name_opt t)
          in
          ", defined on " ^ String.concat ~sep:", " (List.filter_map ~f:typ_to_str types) )
    | None ->
        ""
  in
  (* Check if the annotation is there directly or is modeled. *)
  let get_kind annot pname =
    let pname = get_original_pname annot pname in
    if check_modeled_annotation spec.models annot pname then "modeled as" else "annotated with"
  in
  let src_pname = Procdesc.get_proc_name proc_desc in
  let snk = spec.sink_annotation in
  let snk_annot_str = snk.Annot.class_name in
  let src_annot_str = src.Annot.class_name in
  let access_or_call = if is_dummy_field_pname snk_pname then "accesses" else "calls" in
  let spec_description = prepend_if_not_empty spec.description ". " in
  let spec_name = append_if_not_empty spec.name ". " in
  (* A direct call has a trace of length 3: source def + callsite + sink def *)
  let transitive = if List.length trace > 3 then "transitively " else "" in
  let method_or_constr = if Procname.is_constructor src_pname then "Constructor" else "Method" in
  let description =
    if is_dummy_constructor snk then
      let constr_str = str_of_pname ~withclass:true snk_pname in
      Format.asprintf "%s%s %a annotated with %a allocates %a via %a%s" spec_name method_or_constr
        MF.pp_monospaced (str_of_pname src_pname) MF.pp_monospaced ("@" ^ src_annot_str)
        MF.pp_monospaced constr_str MF.pp_monospaced ("new " ^ constr_str) spec_description
    else
      Format.asprintf "%s%s %a (%s %a%s%s) %s%s %a (%s %a%s%s)%s" spec_name method_or_constr
        MF.pp_monospaced (str_of_pname src_pname) (get_kind src src_pname) MF.pp_monospaced
        ("@" ^ src_annot_str) (get_details src src_pname) (get_class_details src src_pname)
        transitive access_or_call MF.pp_monospaced
        (str_of_pname ~withclass:true snk_pname)
        (get_kind snk snk_pname) MF.pp_monospaced ("@" ^ snk_annot_str) (get_details snk snk_pname)
        (get_class_details snk snk_pname) spec_description
  in
  Reporting.log_issue proc_desc err_log ~loc ~ltr:trace AnnotationReachability spec.issue_type
    description


let start_trace proc_desc annot =
  let description =
    ( if Procname.is_constructor (Procdesc.get_proc_name proc_desc) then "Constructor "
      else "Method " )
    ^ str_of_pname (Procdesc.get_proc_name proc_desc) ~full:true
    ^ ", marked as source @" ^ annot.Annot.class_name
  in
  let loc = Procdesc.get_loc proc_desc in
  if Location.is_dummy loc then [] else [Errlog.make_trace_element 0 loc description []]


let add_to_trace (call_site_info : Domain.call_site_info) end_of_stack snk_annot trace =
  let callee_pname = CallSite.pname call_site_info.call_site in
  let call_loc = CallSite.loc call_site_info.call_site in
  let update ~level loc description trace =
    if Location.is_dummy loc then trace
    else Errlog.make_trace_element level loc description [] :: trace
  in
  let callee_str = str_of_pname callee_pname ~full:true in
  let call_description =
    let call_or_access = if is_dummy_field_pname callee_pname then "accesses " else "calls " in
    let inside_loop = if call_site_info.is_in_loop then " (inside a loop)" else "" in
    call_or_access ^ callee_str ^ inside_loop
  in
  let def_description =
    callee_str ^ " defined here"
    ^ if end_of_stack then ", marked as sink @" ^ snk_annot.Annot.class_name else ""
  in
  let def_loc =
    Option.value_map ~f:ProcAttributes.get_loc ~default:Location.dummy
      (Attributes.load callee_pname)
  in
  trace |> update ~level:1 call_loc call_description |> update ~level:0 def_loc def_description


(* Find paths from a given source procedure to a given sink annotation. If there are multiple
   procedures annotated with the same sink annotation, there will be one path for each of them. *)
let find_paths_to_snk ({InterproceduralAnalysis.proc_desc; tenv} as analysis_data) src
    (spec : AnnotationSpec.t) sink_map =
  let snk_annot = spec.sink_annotation in
  let src_pname = Procdesc.get_proc_name proc_desc in
  let update_loc_if_nonsynth loc caller (call_site_info : Domain.call_site_info) =
    match loc with
    | None ->
        let is_synth =
          Attributes.load caller
          |> Option.exists ~f:(fun (a : ProcAttributes.t) -> a.is_synthetic_method)
        in
        if is_synth then None else Some (CallSite.loc call_site_info.call_site)
    | Some _ ->
        loc
  in
  let first_callsite call_sites =
    (* Just pick one path forward (per sink procedure) to avoid path explosion *)
    try Domain.CallSites.min_elt call_sites
    with Stdlib.Not_found -> L.die InternalError "Callsite map should not be empty"
  in
  let rec step_forward report_loc trace snk_pname (call_site_info : Domain.call_site_info) =
    let callee_pname = CallSite.pname call_site_info.call_site in
    let end_of_stack = Procname.equal callee_pname snk_pname in
    let new_trace = add_to_trace call_site_info end_of_stack snk_annot trace in
    if end_of_stack then
      (* Reached sink, report *)
      match report_loc with
      | Some report_loc ->
          report_src_to_snk_path analysis_data src spec report_loc (List.rev new_trace) callee_pname
      | None ->
          L.debug Analysis Verbose
            "Annotation reachability skipped path %s -> %s all procedures were synthetic@."
            (str_of_pname src_pname) (str_of_pname snk_pname)
    else if
      Config.annotation_reachability_minimize_sources
      && method_overrides_annot src spec.models tenv callee_pname
      || Config.annotation_reachability_minimize_sinks
         && method_overrides_annot snk_annot spec.models tenv callee_pname
    then (* If minimization is enabled and we find a source/sink in the middle, skip this path *)
      ()
    else
      (* Sink not yet reached, thus we have an intermediate step: let's get its summary and recurse *)
      let callee_sink_map = lookup_annotation_calls analysis_data snk_annot callee_pname in
      let next_call_sites =
        try Domain.SinkMap.find snk_pname callee_sink_map
        with Stdlib.Not_found ->
          (* This could happen if some function F says that it can reach H via G
             but G doesn't have an entry for H, which is a bug somewhere else. *)
          L.die InternalError "Sink procedure not found in summary of dependency"
      in
      let next_call_site = first_callsite next_call_sites in
      let report_loc = update_loc_if_nonsynth report_loc callee_pname next_call_site in
      step_forward report_loc new_trace snk_pname next_call_site
  in
  let trace = start_trace proc_desc src in
  Domain.SinkMap.iter
    (fun snk_pname call_sites ->
      let fst_call_site = first_callsite call_sites in
      (* Report the issue where the source makes the first non-synthetic call *)
      let report_loc = update_loc_if_nonsynth None src_pname fst_call_site in
      step_forward report_loc trace snk_pname fst_call_site )
    sink_map


let report_src_and_sink {InterproceduralAnalysis.proc_desc; err_log} src (spec : AnnotationSpec.t) =
  let proc_name = Procdesc.get_proc_name proc_desc in
  let loc = Procdesc.get_loc proc_desc in
  let spec_description = prepend_if_not_empty spec.description ". " in
  let spec_name = append_if_not_empty spec.name ". " in
  let description =
    Format.asprintf "%sMethod %a is annotated with both %a and %a%s" spec_name MF.pp_monospaced
      (str_of_pname proc_name) MF.pp_monospaced ("@" ^ src.Annot.class_name) MF.pp_monospaced
      ("@" ^ spec.sink_annotation.class_name)
      spec_description
  in
  Reporting.log_issue proc_desc err_log ~loc ~ltr:[] AnnotationReachability spec.issue_type
    description


let check_srcs_and_find_snk ({InterproceduralAnalysis.proc_desc; tenv} as analysis_data)
    (spec : AnnotationSpec.t) annot_map =
  let proc_name = Procdesc.get_proc_name proc_desc in
  let check_one_src_and_find_snk src =
    if method_overrides_annot src spec.models tenv proc_name then (
      L.d_printfln "%s: Finding paths from source (`@%s`) `%a`" spec.kind src.Annot.class_name
        Procname.pp proc_name ;
      (* If there are callsites to sinks, find/report such paths. *)
      Option.iter (Domain.find_opt spec.sink_annotation annot_map) ~f:(fun sink_map ->
          find_paths_to_snk analysis_data src spec sink_map ) ;
      (* Reporting something that is both a source and a sink at the same time needs to be
         treated as a special case because there is no call/callsite (path of length 0). *)
      if
        Config.annotation_reachability_report_source_and_sink
        && method_overrides_annot spec.sink_annotation spec.models tenv proc_name
      then report_src_and_sink analysis_data src spec )
  in
  List.iter ~f:check_one_src_and_find_snk spec.source_annotation_list


module StandardAnnotationSpec = struct
  let from_annotations str_src_annots str_snk_annot str_sanitizer_annots name description models =
    let src_list = List.map str_src_annots ~f:annotation_of_str in
    let sanitizer_annots = List.map str_sanitizer_annots ~f:annotation_of_str in
    let snk = annotation_of_str str_snk_annot in
    let open AnnotationSpec in
    { kind= "StandardAnnotationSpec"
    ; sink_predicate= (fun tenv pname -> method_overrides_annot snk models tenv pname)
    ; sanitizer_predicate=
        (fun tenv pname ->
          List.exists sanitizer_annots ~f:(fun s -> method_overrides_annot s models tenv pname) )
    ; sink_annotation= snk
    ; source_annotation_list= src_list
    ; name
    ; description
    ; issue_type= IssueType.checkers_annotation_reachability_error
    ; models
    ; pre_check= (fun _ -> ()) }
end

module NoAllocationAnnotationSpec = struct
  let no_allocation_annot = annotation_of_str Annotations.no_allocation

  let spec =
    let open AnnotationSpec in
    { kind= "NoAllocationAnnotationSpec"
    ; sink_predicate= (fun tenv pname -> is_allocator tenv pname)
    ; sanitizer_predicate=
        (fun tenv pname -> check_attributes Annotations.ia_is_ignore_allocations tenv pname)
    ; sink_annotation= dummy_constructor_annot
    ; source_annotation_list= [no_allocation_annot]
    ; name= ""
    ; description= ""
    ; issue_type= IssueType.checkers_allocates_memory
    ; models= IString.Map.empty
    ; pre_check= (fun _ -> ()) }
end

module ExpensiveAnnotationSpec = struct
  let performance_critical_annot = annotation_of_str Annotations.performance_critical

  let expensive_annot = annotation_of_str Annotations.expensive

  let is_expensive tenv pname = check_attributes Annotations.ia_is_expensive tenv pname

  let method_is_expensive tenv pname = is_modeled_expensive tenv pname || is_expensive tenv pname

  let check_expensive_subtyping_rules {InterproceduralAnalysis.proc_desc; tenv; err_log}
      overridden_pname =
    let proc_name = Procdesc.get_proc_name proc_desc in
    let loc = Procdesc.get_loc proc_desc in
    if not (method_is_expensive tenv overridden_pname) then
      let description =
        Format.asprintf "Method %a overrides unannotated method %a and cannot be annotated with %a"
          MF.pp_monospaced (Procname.to_string proc_name) MF.pp_monospaced
          (Procname.to_string overridden_pname)
          MF.pp_monospaced ("@" ^ Annotations.expensive)
      in
      Reporting.log_issue proc_desc err_log ~loc AnnotationReachability
        IssueType.checkers_expensive_overrides_unexpensive description


  let spec =
    let open AnnotationSpec in
    { kind= "ExpensiveAnnotationSpec"
    ; sink_predicate=
        (fun tenv pname ->
          let has_annot ia = Annotations.ia_ends_with ia expensive_annot.class_name in
          check_attributes has_annot tenv pname || is_modeled_expensive tenv pname )
    ; sanitizer_predicate= (fun _ _ -> false)
    ; sink_annotation= expensive_annot
    ; source_annotation_list= [performance_critical_annot]
    ; name= ""
    ; description= ""
    ; issue_type= IssueType.checkers_calls_expensive_method
    ; models= IString.Map.empty
    ; pre_check=
        (fun ({InterproceduralAnalysis.proc_desc; tenv} as analysis_data) ->
          let proc_name = Procdesc.get_proc_name proc_desc in
          if is_expensive tenv proc_name then
            PatternMatch.override_iter
              (check_expensive_subtyping_rules analysis_data)
              tenv proc_name ) }
end

module MakeTransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = Domain

  type analysis_data =
    { specs: AnnotationSpec.t list
    ; loop_nodes: Control.GuardNodes.t
    ; analysis_data: Domain.t InterproceduralAnalysis.t }

  let check_direct_call tenv ~caller_pname ~callee_pname call_site_info astate specs =
    List.fold ~init:astate specs ~f:(fun astate (spec : AnnotationSpec.t) ->
        if spec.sink_predicate tenv callee_pname then
          if spec.sanitizer_predicate tenv callee_pname then (
            L.d_printfln "%s: Direct call `%a -> %a` to sink `@%s` sanitized by callee `%a`"
              spec.kind Procname.pp caller_pname Procname.pp callee_pname
              spec.sink_annotation.Annot.class_name Procname.pp callee_pname ;
            astate )
          else if spec.sanitizer_predicate tenv caller_pname then (
            L.d_printfln "%s: Direct call `%a -> %a` to sink `@%s` sanitized by caller `%a`"
              spec.kind Procname.pp caller_pname Procname.pp callee_pname
              spec.sink_annotation.Annot.class_name Procname.pp caller_pname ;
            astate )
          else (
            L.d_printfln "%s: Adding direct call `%a -> %a` to sink `@%s`" spec.kind Procname.pp
              caller_pname Procname.pp callee_pname spec.sink_annotation.Annot.class_name ;
            Domain.add_call_site spec.sink_annotation callee_pname call_site_info astate )
        else astate )


  let add_transitive_calls {analysis_data= {proc_desc; tenv; analyze_dependency}; specs}
      call_site_info ~callee_pname astate =
    match analyze_dependency callee_pname with
    | Error err ->
        L.d_printfln "No summary for callee `%a`: %a" Procname.pp callee_pname
          AnalysisResult.pp_no_summary err ;
        astate
    | Ok callee_call_map ->
        L.d_printfln "Applying summary of callee `%a`" Procname.pp callee_pname ;
        let add_call_site annot sink calls astate =
          if Domain.CallSites.is_empty calls then astate
          else
            (* Add the sink to the current state only if the caller pname is not a sanitizer for
               that sink. Ideally we would check only the spec that was responsible for adding the
               sink but it is not obvious how to link back from annot to specs. Instead see if one
               of the specs thinks that this sink is indeed a sink. *)
            let caller_pname = Procdesc.get_proc_name proc_desc in
            List.fold ~init:astate specs ~f:(fun astate (spec : AnnotationSpec.t) ->
                if spec.sink_predicate tenv sink then
                  if spec.sanitizer_predicate tenv callee_pname then (
                    (* I don't think this branch can happen, if callee is sanitizer then call
                       to sink should not appear in its summary. But better be safe. *)
                    L.d_printfln
                      "%s: Indirect call `%a -> %a` to sink `@%s` sanitized by callee `%a`"
                      spec.kind Procname.pp caller_pname Procname.pp sink
                      spec.sink_annotation.Annot.class_name Procname.pp callee_pname ;
                    astate )
                  else if spec.sanitizer_predicate tenv caller_pname then (
                    L.d_printfln
                      "%s: Indirect call `%a -> %a` to sink `@%s` sanitized by caller `%a`"
                      spec.kind Procname.pp caller_pname Procname.pp sink
                      spec.sink_annotation.Annot.class_name Procname.pp caller_pname ;
                    astate )
                  else (
                    L.d_printfln "%s: Adding transitive call `%a -> %a` to sink `@%s`" spec.kind
                      Procname.pp caller_pname Procname.pp sink
                      spec.sink_annotation.Annot.class_name ;
                    Domain.add_call_site annot sink call_site_info astate )
                else astate )
        in
        Domain.fold
          (fun annot sink_map astate -> Domain.SinkMap.fold (add_call_site annot) sink_map astate)
          callee_call_map astate


  let exec_instr astate ({analysis_data= {proc_desc; tenv}; loop_nodes; specs} as analysis_data)
      node _ instr =
    match instr with
    | Sil.Call (_, Const (Cfun callee_pname), _, call_loc, _) ->
        let caller_pname = Procdesc.get_proc_name proc_desc in
        let call_site_info : Domain.call_site_info =
          { call_site= CallSite.make callee_pname call_loc
          ; is_in_loop= Control.GuardNodes.mem node loop_nodes }
        in
        check_direct_call tenv ~callee_pname ~caller_pname call_site_info astate specs
        |> add_transitive_calls analysis_data call_site_info ~callee_pname
    | Sil.Load {e= Exp.Lfield (_, fieldname, typ); loc} ->
        (* Pretend that field access is a call to a fake method (containing the name of the field).
           Currently only supported for Java. *)
        if Language.curr_language_is Java then
          let caller_pname = Procdesc.get_proc_name proc_desc in
          let callee_pname = dummy_pname_for_field fieldname typ in
          let call_site_info : Domain.call_site_info =
            { call_site= CallSite.make callee_pname loc
            ; is_in_loop= Control.GuardNodes.mem node loop_nodes }
          in
          check_direct_call tenv ~callee_pname ~caller_pname call_site_info astate specs
        else astate
    | _ ->
        astate


  let pp_session_name _node fmt = F.pp_print_string fmt "annotation reachability"
end

module TransferFunctions = MakeTransferFunctions (ProcCfg.Exceptional)
module Analyzer = AbstractInterpreter.MakeRPO (TransferFunctions)

type custom_spec =
  { sources: string list
  ; sinks: string list
  ; sanitizers: string list [@yojson.default []]
  ; name: string [@yojson.default ""]
  ; description: string [@yojson.default ""] }
[@@deriving of_yojson]

type custom_specs = custom_spec list [@@deriving of_yojson]

let parse_custom_specs () =
  let models = parse_custom_models () in
  let make_standard_spec_from_custom_spec {sources; sinks; sanitizers; name; description} =
    List.map
      ~f:(fun sink ->
        StandardAnnotationSpec.from_annotations sources sink sanitizers name description models )
      sinks
  in
  let custom_specs =
    let specs =
      try custom_specs_of_yojson Config.annotation_reachability_custom_pairs
      with _ -> L.die ExternalError "Could not parse annotation reachability custom pairs@."
    in
    List.map specs ~f:make_standard_spec_from_custom_spec
  in
  List.concat custom_specs


let compute_loop_nodes proc_desc =
  if Config.annotation_reachability_check_loops then
    let cfg = ProcCfg.NormalOneInstrPerNode.from_pdesc proc_desc in
    Procdesc.Loop.compute_loop_nodes cfg
  else Control.GuardNodes.empty


let checker ({InterproceduralAnalysis.proc_desc} as analysis_data) : Domain.t option =
  let loop_nodes = compute_loop_nodes proc_desc in
  let initial = Domain.empty in
  let custom_specs = parse_custom_specs () in
  let expensive_specs =
    if Config.annotation_reachability_expensive then [ExpensiveAnnotationSpec.spec] else []
  in
  let no_alloc_specs =
    if Config.annotation_reachability_no_allocation then [NoAllocationAnnotationSpec.spec] else []
  in
  let specs = expensive_specs @ no_alloc_specs @ custom_specs in
  let proc_data = {TransferFunctions.analysis_data; loop_nodes; specs} in
  let post = Analyzer.compute_post proc_data ~initial proc_desc in
  let pp_name f = F.pp_print_string f "annotation reachability reporting" in
  AnalysisCallbacks.html_debug_new_node_session (Procdesc.get_exit_node proc_desc)
    ~pp_name ~kind:`ExecNode ~f:(fun () ->
      Option.iter post ~f:(fun annot_map ->
          List.iter specs ~f:(fun spec ->
              spec.AnnotationSpec.pre_check analysis_data ;
              check_srcs_and_find_snk analysis_data spec annot_map ) ) ) ;
  post
