(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Hack_parallel.Std
module Daemon = Daemon
open Core

type t = {
  is_parallel: bool;
  workers: Worker.t list;
  number_of_workers: int;
}

module Policy = struct
  type t = number_of_workers:int -> number_of_tasks:int -> int

  let divide_work ~number_of_workers ~number_of_tasks policy =
    policy ~number_of_workers ~number_of_tasks


  let legacy_fixed_chunk_size chunk_size =
    assert (chunk_size > 0);
    fun ~number_of_workers ~number_of_tasks ->
      Core.Int.max number_of_workers ((number_of_tasks / chunk_size) + 1)


  let legacy_fixed_chunk_count () ~number_of_workers ~number_of_tasks =
    Core.Int.max
      number_of_workers
      (let chunk_multiplier = Core.Int.min 10 (1 + (number_of_tasks / 400)) in
       number_of_workers * chunk_multiplier)


  let fixed_chunk_size ?mininum_chunk_size ~minimum_chunks_per_worker ~preferred_chunk_size () =
    let minimum_chunk_size = Option.value mininum_chunk_size ~default:preferred_chunk_size in
    assert (minimum_chunk_size >= 0);
    assert (preferred_chunk_size >= minimum_chunk_size);
    assert (minimum_chunks_per_worker >= 0);
    fun ~number_of_workers ~number_of_tasks ->
      let preferred_chunk_count = (number_of_tasks / preferred_chunk_size) + 1 in
      let minimum_chunk_count = minimum_chunks_per_worker * number_of_workers in
      if preferred_chunk_count >= minimum_chunk_count then
        preferred_chunk_count
      else
        let fallback_chunk_size = number_of_tasks / minimum_chunk_count in
        if fallback_chunk_size >= minimum_chunk_size then
          minimum_chunk_count
        else
          1


  let fixed_chunk_count
      ?minimum_chunks_per_worker
      ~minimum_chunk_size
      ~preferred_chunks_per_worker
      ()
    =
    let minimum_chunks_per_worker =
      Option.value minimum_chunks_per_worker ~default:preferred_chunks_per_worker
    in
    assert (minimum_chunks_per_worker >= 0);
    assert (preferred_chunks_per_worker >= minimum_chunks_per_worker);
    assert (minimum_chunks_per_worker >= 0);
    fun ~number_of_workers ~number_of_tasks ->
      let preferred_chunk_count = preferred_chunks_per_worker * number_of_workers in
      let preferred_chunk_size = number_of_tasks / preferred_chunk_count in
      if preferred_chunk_size >= minimum_chunk_size then
        preferred_chunk_count
      else
        let minimum_chunk_count = minimum_chunks_per_worker * number_of_workers in
        let fallback_chunk_count = (number_of_tasks / minimum_chunk_size) + 1 in
        if fallback_chunk_count >= minimum_chunk_count then
          fallback_chunk_count
        else
          1
end

let entry = Worker.register_entry_point ~restore:(fun _ -> ())

let create
    ~configuration:({ Configuration.Analysis.parallel; number_of_workers; _ } as configuration)
    ()
  =
  let heap_handle = Memory.get_heap_handle configuration in
  let workers =
    Hack_parallel.Std.Worker.make
      ~saved_state:()
      ~entry
      ~nbr_procs:number_of_workers
      ~heap_handle
      ~gc_control:Memory.worker_garbage_control
  in
  { workers; number_of_workers; is_parallel = parallel }


let run_process
    ~configuration:({ Configuration.Analysis.verbose; sections; _ } as configuration)
    process
  =
  Log.initialize ~verbose ~sections;
  Configuration.Analysis.set_global configuration;
  try
    let result = process () in
    Statistics.flush ();
    result
  with
  | error -> raise error


let map_reduce
    { workers; number_of_workers; is_parallel; _ }
    ~policy
    ~configuration
    ~initial
    ~map
    ~reduce
    ~inputs
    ()
  =
  let sequential_map_reduce () = map initial inputs |> fun mapped -> reduce mapped initial in
  if is_parallel then
    let number_of_chunks =
      Policy.divide_work ~number_of_workers ~number_of_tasks:(List.length inputs) policy
    in
    if number_of_chunks = 1 then
      sequential_map_reduce ()
    else
      let map accumulator inputs =
        (fun () -> map accumulator inputs) |> run_process ~configuration
      in
      MultiWorker.call
        (Some workers)
        ~job:map
        ~merge:reduce
        ~neutral:initial
        ~next:(Bucket.make ~num_workers:number_of_chunks inputs)
  else
    sequential_map_reduce ()


let iter scheduler ~policy ~configuration ~f ~inputs =
  map_reduce
    scheduler
    ~policy
    ~configuration
    ~initial:()
    ~map:(fun _ inputs -> f inputs)
    ~reduce:(fun _ _ -> ())
    ~inputs
    ()


let single_job { workers; _ } ~f work =
  let rec wait_until_ready handle =
    let { Worker.readys; _ } = Worker.select [handle] in
    match readys with
    | [] -> wait_until_ready handle
    | ready :: _ -> ready
  in
  match workers with
  | worker :: _ -> Worker.call worker f work |> wait_until_ready |> Worker.get_result
  | [] -> failwith "This service contains no workers"


let mock () =
  let configuration = Configuration.Analysis.create () in
  Memory.get_heap_handle configuration |> ignore;
  { workers = []; number_of_workers = 1; is_parallel = false }


let is_parallel { is_parallel; _ } = is_parallel

let workers { workers; _ } = workers

let destroy _ = Worker.killall ()

let once_per_worker { workers; number_of_workers; _ } ~configuration:_ ~f =
  MultiWorker.call
    (Some workers)
    ~job:(fun _ _ -> f ())
    ~merge:(fun _ _ -> ())
    ~neutral:()
    ~next:
      (Bucket.make ~num_workers:number_of_workers (List.init number_of_workers ~f:(fun _ -> ())))
