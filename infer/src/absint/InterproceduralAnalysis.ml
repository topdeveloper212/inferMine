(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type 'payload t =
  { proc_desc: Procdesc.t
  ; tenv: Tenv.t
  ; err_log: Errlog.t
  ; analyze_dependency: ?specialization:Specialization.t -> Procname.t -> 'payload AnalysisResult.t
  ; add_errlog: Procname.t -> Errlog.t -> unit }

let for_procedure proc_desc err_log data = {data with proc_desc; err_log}

type 'payload file_t =
  { source_file: SourceFile.t
  ; procedures: Procname.t list
  ; analyze_file_dependency: Procname.t -> 'payload AnalysisResult.t }

let bind_payload_opt analysis_data ~f =
  { analysis_data with
    analyze_dependency=
      (fun ?specialization proc_name ->
        analysis_data.analyze_dependency ?specialization proc_name
        |> Result.bind ~f:(fun payload -> f payload |> AnalysisResult.of_option) ) }
