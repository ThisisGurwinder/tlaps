(*
 * mod/save.ml --- saving and loading modules
 *
 *
 * Copyright (C) 2008-2010  INRIA and Microsoft Corporation
 *)

Revision.f "$Rev: 32098 $";;

open Property
open Util.Coll

open Tla_parser
open Tla_parser.P

open M_t
open M_parser

(*let debug = Printf.eprintf;;*)

exception Unknown_module_exception
exception Not_loadable_exception of string wrapped

let clocking cl fn x = match cl with
  | Some cl ->
      Timing.start cl ;
      let ret = fn x in
      Timing.stop () ;
      ret
  | None ->
      fn x

let file_search fh =
  if Filename.is_implicit fh.core then
    let rec scan = function
      | [] -> None
      | d :: ds ->
          let f = Filename.concat d fh.core in
          if Sys.file_exists f then Some (f @@ fh) else scan ds
    in scan ("." :: List.rev !Params.rev_search_path)
  else
    if Sys.file_exists fh.core then Some fh else None

let really_parse_file fn = match file_search fn with
  | None ->
      Util.eprintf ~at:fn
        "Could not find file %S in the search path." fn.core ;
      Errors.set fn (Printf.sprintf "Could not find file %S in the search path." fn.core);
      failwith "Module.Parser.parse_file"
  | Some fn ->
      let expname = Filename.chop_suffix (Filename.basename fn.core) ".tla" in
      let (flex, _) = Alexer.lex fn.core in
      let htest =
        (punct "----" >*> kwd "MODULE" >*> anyname <<< punct "----"
         <?> (fun nm -> nm = expname)) in
      let hparse = enabled htest >>> use parse in
      match P.run hparse ~init:Tla_parser.init ~source:flex with
        | None ->
            Util.eprintf ~at:fn
              "Could not parse %S successfully." fn.core ;
            Errors.set fn (Printf.sprintf  "Could not parse %S successfully." fn.core);
            failwith "Module.Parser.parse_file"
        | Some mule ->
            if !Params.verbose then
              Util.printf "(* module %S parsed from %S *)"
                mule.core.name.core fn.core ;
            mule

let validate mn inch =
  let v : string = Marshal.from_channel inch in
  if v = Params.rawversion () then
    let h = Digest.input inch in
    if h = Params.self_sum then
      let csum = Digest.input inch in
      let mule : mule = Marshal.from_channel inch in
      (close_in inch ; Some (csum, mule))
    else (close_in inch ; None)
  else (close_in inch ; None)

let rec really_load_module mn fn fnx = match fn, fnx with
  | Some _, Some _ when not !Params.use_xtla ->
      really_load_module mn fn None
  | None, None ->
      (*   Util.eprintf ~at:mn
        "Unknown module %S" mn.core ;
      Errors.set mn (Printf.sprintf  "Unknown module %S" mn.core);
      failwith "Module.Parser.load_module" *)
      raise Unknown_module_exception
  | Some fn, None ->
      really_parse_file fn
  | None, Some fnx -> begin match validate mn (open_in_bin fnx.core) with
      | Some (_, m) ->
          if !Params.verbose then
            Util.printf "(* module %S loaded from %S *)"
              m.core.name.core fnx.core ;
          m
      | None ->
          (* Util.eprintf ~at:fnx
            "%S not loadable\nNo corresponding source found either!" fnx.core  ;
          failwith "Module.Parser.load_module"*)
        raise (Not_loadable_exception fnx)
    end
  | Some fn, Some fnx -> begin match validate mn (open_in_bin fnx.core) with
      | Some (csum, m) when csum = Digest.file fn.core ->
          if !Params.verbose then
            Util.printf "(* module %S loaded from %S *)"
              m.core.name.core fnx.core ;
          m
      | _ -> really_parse_file fn
    end

let load_module ?clock ?root:(r="") mn =
    clocking clock begin fun () ->
      let fn = (Filename.concat r (mn.core ^ ".tla")) @@ mn in
      let fnx = (Filename.concat r (mn.core ^ ".xtla")) @@ mn in
      really_load_module mn (file_search fn) (file_search fnx)
    end ()

let parse_file ?clock gfn =
  clocking clock begin fun () ->
    let fn = begin
      if Filename.check_suffix gfn.core ".tla" then
        Filename.chop_suffix gfn.core ".tla"
      else gfn.core
    end @@ gfn in
    let mn = (Filename.basename fn.core) @@ fn in
    let fnx = file_search ((fn.core ^ ".xtla") @@ fn) in
    let fn = file_search ((fn.core ^ ".tla") @@ fn) in
    if fn = None && fnx = None then begin
      Util.eprintf ~at:gfn "File %S not found" gfn.core ;
      Errors.set gfn (Printf.sprintf "File %s not found" gfn.core);
      failwith "Module.Parser.parse_file"
    end else really_load_module mn fn fnx
  end ()

let complete_load ?clock ?root:(r="") mcx =
  clocking clock begin fun () ->
    let mods = ref Deque.empty in
    Sm.iter (fun _ mule -> mods := Deque.snoc !mods mule) mcx ;
    let rec spin mcx = match Deque.front !mods with
      | None -> mcx
      | Some (mule, rest) ->
          mods := rest ;
          let eds = M_dep.external_deps mule in
          let mcx = Hs.fold begin
            fun ed mcx ->
              let mn = ed in
              (* if module name is also a name of a standrd module, try to load it anyway *)
              if (Sm.mem ed.core M_standard.initctx) then
                try
                  let emule = load_module ~root:r ed in
                  mods := Deque.snoc !mods emule ;
                  Sm.add ed.core emule mcx
                with Unknown_module_exception ->
                    (* expected behavior - standard module will be used *)
                    mcx
                | Not_loadable_exception fnx ->
                    Util.eprintf ~at:fnx
                    "%S not loadable\nNo corresponding source found either!" fnx.core  ;
                    failwith "Module.Parser.load_module"
              (* else load it only if it was not loaded already *)
              else if (Sm.mem ed.core mcx) then mcx
              else try
                let emule = load_module ~root:r ed in
                mods := Deque.snoc !mods emule ;
                Sm.add ed.core emule mcx
              with Unknown_module_exception ->
                   Util.eprintf ~at:mn
                   "Unknown module %S" mn.core ;
                   Errors.set mn (Printf.sprintf  "Unknown module %S" mn.core);
                   failwith "Module.Parser.load_module"
              | Not_loadable_exception fnx ->
                  Util.eprintf ~at:fnx
                  "%S not loadable\nNo corresponding source found either!" fnx.core  ;
                  failwith "Module.Parser.load_module"
          end eds mcx in
          spin mcx
    in
    spin mcx
  end ()

let store_module ?clock mule =
  if !Params.xtla then
    clocking clock begin fun () ->
      let fn = (Util.get_locus mule).Loc.file in
      let fnx = Filename.chop_extension fn ^ ".xtla" in
      let fx = open_out_bin fnx in
      Marshal.to_channel fx Params.rawversion [] ;
      Digest.output fx Params.self_sum ;
      Digest.output fx (Digest.file fn) ;
      Marshal.to_channel fx mule [] ;
      close_out fx ;
      if !Params.verbose then
        Util.printf "(* compiled module %S saved to %S *)"
          mule.core.name.core fnx
    end ()
  else ()
