(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module L = Logging
open TaskSchedulerTypes
module Node = SpecializedProcname
module NodeSet = SpecializedProcname.Set

let read_procs_to_analyze () =
  Option.value_map ~default:NodeSet.empty Config.procs_to_analyze_index ~f:(fun index ->
      In_channel.read_all index |> Parsexp.Single.parse_string_exn |> NodeSet.t_of_sexp )


type target_with_dependency = {target: TaskSchedulerTypes.target; dependency_filename: string}

let of_queue ready : ('a, TaskSchedulerTypes.analysis_result) ProcessPool.TaskGenerator.t =
  let remaining = ref (Queue.length ready) in
  let blocked = Queue.create () in
  let remaining_tasks () = !remaining in
  let is_empty () = Int.equal !remaining 0 in
  let finished ~result target =
    match result with
    | None | Some Ok ->
        decr remaining
    | Some (RaceOn {dependency_filename}) ->
        Queue.enqueue blocked {target; dependency_filename}
  in
  let rec check_for_readiness n =
    (* check the next [n] items in [blocked] for whether their dependencies are satisfied and
       they can be moved to the [ready] queue *)
    if n > 0 then (
      let w = Queue.dequeue_exn blocked in
      if ProcLocker.is_locked ~proc_filename:w.dependency_filename then Queue.enqueue blocked w
      else Queue.enqueue ready w.target ;
      check_for_readiness (n - 1) )
  in
  let next () =
    if Queue.is_empty ready then check_for_readiness (Queue.length blocked) ;
    Queue.dequeue ready
  in
  {remaining_tasks; is_empty; finished; next}


let make sources =
  let target_count = ref 0 in
  let cons_procname_work acc ~specialization proc_name =
    incr target_count ;
    Procname {proc_name; specialization} :: acc
  in
  let procs_to_analyze_targets =
    NodeSet.fold
      (fun {Node.proc_name; specialization} acc -> cons_procname_work acc ~specialization proc_name)
      (read_procs_to_analyze ()) []
  in
  let pname_targets =
    List.fold sources ~init:procs_to_analyze_targets ~f:(fun init source ->
        SourceFiles.proc_names_of_source source
        |> List.fold ~init ~f:(cons_procname_work ~specialization:None) )
  in
  let make_file_work file =
    incr target_count ;
    TaskSchedulerTypes.File file
  in
  let file_targets = List.rev_map sources ~f:make_file_work in
  let queue = Queue.create ~capacity:!target_count () in
  let permute_and_enqueue targets =
    List.permute targets ~random_state:(Random.State.make (Array.create ~len:1 0))
    |> List.iter ~f:(Queue.enqueue queue)
  in
  permute_and_enqueue pname_targets ;
  permute_and_enqueue file_targets ;
  of_queue queue


let if_restart_scheduler f =
  match Config.scheduler with File | SyntacticCallGraph -> () | Restart -> f ()


let setup () = if_restart_scheduler ProcLocker.setup

type locked_proc = {start: ExecutionDuration.counter; mutable callees_useful: ExecutionDuration.t}

let locked_procs = Stack.create ()

let lock_exn pname =
  if ProcLocker.try_lock pname then
    Stack.push locked_procs
      {start= ExecutionDuration.counter (); callees_useful= ExecutionDuration.zero}
  else
    raise
      (RestartSchedulerException.ProcnameAlreadyLocked
         {dependency_filename= Procname.to_filename pname} )


let unlock ~after_exn pname =
  match Stack.pop locked_procs with
  | None ->
      L.internal_error "Trying to unlock %a but it does not appear to be locked.@\n" Procname.pp
        pname
  | Some {start; callees_useful} ->
      ( match Stack.top locked_procs with
      | Some caller ->
          caller.callees_useful <-
            ( if after_exn then ExecutionDuration.add caller.callees_useful callees_useful
              else ExecutionDuration.add_duration_since caller.callees_useful start )
      | None ->
          Stats.add_to_restart_scheduler_useful_time
            (if after_exn then callees_useful else ExecutionDuration.since start) ;
          Stats.add_to_restart_scheduler_total_time (ExecutionDuration.since start) ) ;
      ProcLocker.unlock pname


let with_lock ~f pname =
  match Config.scheduler with
  | File | SyntacticCallGraph ->
      f ()
  | Restart when Int.equal Config.jobs 1 ->
      f ()
  | Restart ->
      lock_exn pname ;
      let res =
        try f () with exn -> IExn.reraise_after ~f:(fun () -> unlock ~after_exn:true pname) exn
      in
      unlock ~after_exn:false pname ;
      res


let finish result task = match result with None | Some Ok -> None | Some (RaceOn _) -> Some task
