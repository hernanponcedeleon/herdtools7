(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2015-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)
(* Authors:                                                                 *)
(* Hadrien Renaud, University College London, UK.                           *)
(****************************************************************************)

module type S = sig
  type vint
  type vbool
  type vreal
  type vbitvector
  type 'a m
  type loc
  type value = (vint, vbool, vreal, vbitvector) AST.value
  type scope = AST.identifier * int

  val vint_of_int : int -> vint
  val bind_data : 'a m -> ('a -> 'b m) -> 'b m
  val bind_seq : 'a m -> ('a -> 'b m) -> 'b m
  val prod : 'a m -> 'b m -> ('a * 'b) m

  val choice : value m -> 'b m -> 'b m -> 'b m
  (** choice is a boolean if operator *)

  val return : 'a -> 'a m
  val fatal : string -> 'a m
  val binop : AST.binop -> value -> value -> value m
  val unop : AST.unop -> value -> value m
  val on_write_identifier : AST.identifier -> scope -> value -> unit m
  val on_read_identifier : AST.identifier -> scope -> value -> unit m
end
