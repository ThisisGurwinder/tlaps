(*
 * prf/prep.ml --- ship obligations
 *
 *
 * Copyright (C) 2008-2010  INRIA and Microsoft Corporation
 *)

(** Ship obligations to the backend *)

open Proof.T
open Types;;

val make_task :
  out_channel ->
  out_channel ->
  (bool -> obligation -> unit) ->
  obligation ->
    Schedule.task
;;

val expand_defs : ?what:(Expr.T.wheredef -> bool) -> obligation -> obligation

val normalize : obligation -> obligation
