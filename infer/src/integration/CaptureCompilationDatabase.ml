(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging

let create_cmd (source_file, (compilation_data : CompilationDatabase.compilation_data)) =
  let swap_executable cmd =
    if String.is_suffix ~suffix:"++" cmd then Config.wrappers_dir ^/ "clang++"
    else Config.wrappers_dir ^/ "clang"
  in
  let arg_file =
    ClangQuotes.mk_arg_file "cdb_clang_args" ClangQuotes.EscapedNoQuotes
      compilation_data.escaped_arguments
  in
  ( source_file
  , { CompilationDatabase.directory= compilation_data.directory
    ; executable= swap_executable compilation_data.executable
    ; escaped_arguments=
        ["@" ^ arg_file; "-fsyntax-only"; "-fno-builtin"] @ Config.clang_extra_flags } )


let invoke_cmd (source_file, (cmd : CompilationDatabase.compilation_data)) =
  let argv = cmd.executable :: cmd.escaped_arguments in
  ( ( match Spawn.spawn ~cwd:(Path cmd.directory) ~prog:cmd.executable ~argv () with
    | pid ->
        !WorkerPoolState.update_status
          (Some (Mtime_clock.now ()))
          (SourceFile.to_string source_file) ;
        IUnix.waitpid (Pid.of_int pid)
        |> Result.map_error ~f:(fun unix_error ->
               IUnix.Exit_or_signal.to_string_hum (Error unix_error) )
    | exception Unix.Unix_error (err, f, arg) ->
        Error (F.asprintf "%s(%s): %s@." f arg (IUnix.Error.message err)) )
  |> function
  | Ok () ->
      ()
  | Error error ->
      let log_or_die fmt =
        if Config.keep_going then L.debug Capture Quiet fmt else L.die ExternalError fmt
      in
      log_or_die "Error running compilation for '%a': %a:@\n%s@." SourceFile.pp source_file
        Pp.cli_args argv error ) ;
  None


let run_compilation_database compilation_database should_capture_file =
  let compilation_data =
    CompilationDatabase.filter_compilation_data compilation_database ~f:should_capture_file
  in
  let number_of_jobs = List.length compilation_data in
  L.(debug Capture Quiet)
    "Starting %s %d files@\n%!" Config.clang_frontend_action_string number_of_jobs ;
  L.progress "Starting %s %d files@\n%!" Config.clang_frontend_action_string number_of_jobs ;
  let compilation_commands = List.map ~f:create_cmd compilation_data in
  let tasks () =
    TaskGenerator.of_list ~finish:TaskGenerator.finish_always_none compilation_commands
  in
  (* no stats to record so [child_epilogue] does nothing and we ignore the return
     {!ProcessPool.run} *)
  let runner =
    ProcessPool.create ~jobs:Config.jobs ~child_prologue:ignore ~f:invoke_cmd ~child_epilogue:ignore
      ~tasks ()
  in
  ProcessPool.run runner |> ignore ;
  L.progress "@." ;
  L.(debug Analysis Medium) "Ran %d jobs" number_of_jobs


let get_compilation_database_files_xcodebuild ~prog ~args =
  let tmp_file = IFilename.temp_file ~in_dir:(ResultsDir.get_path Temporary) "cdb" ".json" in
  let xcodebuild_prog, xcodebuild_args = (prog, prog :: args) in
  let xcpretty_prog = "xcpretty" in
  let xcpretty_args =
    [xcpretty_prog; "--report"; "json-compilation-database"; "--output"; tmp_file]
  in
  L.(debug Capture Quiet)
    "Running %s | %s@\n@."
    (List.to_string ~f:Fn.id xcodebuild_args)
    (List.to_string ~f:Fn.id xcpretty_args) ;
  let producer_status, consumer_status =
    Process.pipeline ~producer_prog:xcodebuild_prog ~producer_args:xcodebuild_args
      ~consumer_prog:xcpretty_prog ~consumer_args:xcpretty_args
  in
  match (producer_status, consumer_status) with
  | Ok (), Ok () ->
      [`Escaped tmp_file]
  | _ ->
      L.(die ExternalError) "There was an error executing the build command"


let is_skipped source_file =
  Option.exists
    ~f:(fun re -> Str.string_match re (SourceFile.to_rel_path source_file) 0)
    Config.skip_analysis_in_path


let capture_files_in_database ~changed_files compilation_database =
  let should_capture =
    match changed_files with
    | None ->
        fun source_file -> not (is_skipped source_file)
    | Some changed_files_set ->
        fun source_file ->
          (not (is_skipped source_file)) && SourceFile.Set.mem source_file changed_files_set
  in
  run_compilation_database compilation_database should_capture


let capture ~changed_files ~db_files =
  let root = Config.project_root in
  let clang_compilation_dbs =
    List.map db_files ~f:(function
      | `Escaped fname ->
          `Escaped (Utils.filename_to_absolute ~root fname)
      | `Raw fname ->
          `Raw (Utils.filename_to_absolute ~root fname) )
  in
  let compilation_database = CompilationDatabase.from_json_files clang_compilation_dbs in
  capture_files_in_database ~changed_files compilation_database
