(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging

[@@@warning "+missing-record-field-pattern"]

type action = ReadStdout | ReadStderr

let create_process_and_wait_with_output ~prog ~args ?(env = `Extend []) action =
  let redirected_fd_name, redirect_spec =
    match action with ReadStderr -> ("stderr", "2>") | ReadStdout -> ("stdout", ">")
  in
  let output_file =
    IFilename.temp_file ~in_dir:(ResultsDir.get_path Temporary) prog redirected_fd_name
  in
  let escaped_cmd = List.map ~f:Escape.escape_shell (prog :: args) |> String.concat ~sep:" " in
  let redirected_cmd = Printf.sprintf "exec %s %s'%s'" escaped_cmd redirect_spec output_file in
  let {IUnix.Process_info.stdin; stdout; stderr; pid} =
    IUnix.create_process_env ~prog:"sh" ~args:["-c"; redirected_cmd] ~env
  in
  let fd_to_log, redirected_fd =
    match action with ReadStderr -> (stdout, stderr) | ReadStdout -> (stderr, stdout)
  in
  let channel_to_log = Unix.in_channel_of_descr fd_to_log in
  Utils.with_channel_in channel_to_log ~f:(L.progress "%s-%s: %s@." prog redirected_fd_name) ;
  In_channel.close channel_to_log ;
  Unix.close redirected_fd ;
  Unix.close stdin ;
  match IUnix.waitpid pid with
  | Ok () ->
      Utils.with_file_in output_file ~f:In_channel.input_all
  | Error _ as status ->
      L.die ExternalError "Error executing: %a@\n%s@\n" Pp.cli_args (prog :: args)
        (IUnix.Exit_or_signal.to_string_hum status)


(** Given a command to be executed, create a process to execute this command, and wait for it to
    terminate. If the command fails to execute, print an error message and exit. *)
let create_process_and_wait ~prog ~args ?env () =
  create_process_and_wait_with_output ~prog ~args ?env ReadStdout |> ignore


let pipeline ~producer_prog ~producer_args ~consumer_prog ~consumer_args =
  let pipe_in, pipe_out = Unix.pipe () in
  let producer_args = Array.of_list producer_args in
  let consumer_args = Array.of_list consumer_args in
  let producer_pid =
    UnixLabels.create_process ~prog:producer_prog ~args:producer_args ~stdin:Unix.stdin
      ~stdout:pipe_out ~stderr:Unix.stderr
  in
  let consumer_pid =
    UnixLabels.create_process ~prog:consumer_prog ~args:consumer_args ~stdin:pipe_in
      ~stdout:Unix.stdout ~stderr:Unix.stderr
  in
  (* wait for children *)
  let producer_status = IUnix.waitpid (Pid.of_int producer_pid) in
  let consumer_status = IUnix.waitpid (Pid.of_int consumer_pid) in
  Unix.close pipe_out ;
  Unix.close pipe_in ;
  (producer_status, consumer_status)
