(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open PulseBasicInterface
open PulseModelsImport

module ProcNameDispatcher = struct
  let dispatch : (Tenv.t * Procname.t, model, ValueOrigin.t) ProcnameDispatcher.Call.dispatcher =
    ProcnameDispatcher.Call.make_dispatcher
      ( FbPulseModels.matchers @ PulseModelsCSharp.matchers
      @ PulseModelsObjC.transfer_ownership_matchers @ PulseModelsCpp.abort_matchers
      @ PulseModelsAndroid.matchers @ PulseModelsC.matchers @ PulseModelsCpp.matchers
      @ PulseModelsErlang.matchers @ PulseModelsGenericArrayBackedCollection.matchers
      @ PulseModelsHack.matchers @ PulseModelsJava.matchers @ PulseModelsObjC.matchers
      @ PulseModelsOptional.matchers @ PulseModelsSmartPointers.matchers @ PulseModelsLocks.matchers
      @ Basic.matchers )
end

let dispatch tenv proc_name args =
  match ProcNameDispatcher.dispatch (tenv, proc_name) proc_name args with
  | None ->
      PulseModelsErlang.get_model_from_db proc_name args |> Option.map ~f:lift_model
  | m ->
      m


let dispatch_builtins proc_name args =
  match proc_name with
  | Procname.Python (PythonProcname.Builtin builtin) ->
      let args =
        List.map
          ~f:(fun func_arg ->
            ProcnameDispatcher.Call.FuncArg.arg_payload func_arg |> ValueOrigin.addr_hist )
          args
      in
      Some (PulseModelsPython.builtins_matcher builtin args)
  | _ ->
      None
