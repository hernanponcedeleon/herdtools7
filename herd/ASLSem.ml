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

(*
   A quick note on monads:
   -----------------------

   We use three main connecters here:
    - the classic data binder ( [>>=] )
    - a control binder ( [>>*=] or assimilate)
    - a sequencing operator ( [M.aslseq] )
   And some specialized others:
    - the parallel operator ( [>>|] )
    - a choice operation

   Monad type has:
   - input: EventSet
   - output: EventSet
   - data_input: EventSet
   - ctrl_output: EventSet
   - iico_data: EventRel
   - iico_ctrl: EventRel

   Description of the main data binders:

   - _data_ binders:
     iico_data U= 1.output X 2.data_input
     input = 1.input (or 2.input if 1 is empty)
        same with data_input
     output = 2.ouput (or 1.output if 2.output is None)
        same-ish with ctrl_output

   - _seq_ binder (called [aslseq]):
     input = 1.input U 2.input
        same with data_input
     output = 2.output
     ctrl_output = 1.ctrl_output U 2.ctrl_output

   - _ctrl_ binder (called [bind_ctrl_seq_data]):
     iico_ctrl U= 1.ctrl_output X 2.input
     input = 1.input (or 2.input if 1 is empty)
        same with data_input
     output = 2.output (or 1.output if 2.output is None)
        same-ish with ctrl_output
 *)

module AST = Asllib.AST

module type Config = sig
  include Sem.Config

  val libfind : string -> string
end

module Make (C : Config) = struct
  module V = ASLValue.V

  module ConfLoc = struct
    include SemExtra.ConfigToArchConfig (C)

    let default_to_symb = C.variant Variant.ASL
  end

  module ASL64AH = struct
    include GenericArch_herd.Make (ASLBase) (ConfLoc) (V)
    include ASLBase

    let opt_env = true
  end

  module Act = ASLAction.Make (ASL64AH)
  include SemExtra.Make (C) (ASL64AH) (Act)

  let barriers = []
  let isync = None
  let atomic_pair_allowed _ _ = true

  module Mixed (SZ : ByteSize.S) : sig
    val build_semantics : test -> A.inst_instance_id -> (proc * branch) M.t
    val spurious_setaf : A.V.v -> unit M.t
  end = struct
    module Mixed = M.Mixed (SZ)

    let ( let* ) = M.( >>= )
    let ( let*| ) = M.aslseq
    let ( and* ) = M.( >>| )
    let return = M.unitT
    let ( >>= ) = M.( >>= )
    let ( >>! ) = M.( >>! )

    (**************************************************************************)
    (* ASL-PO handling                                                        *)
    (**************************************************************************)

    let incr (poi : A.program_order_index ref) : A.program_order_index =
      let i = !poi in
      let () = poi := A.next_po_index i in
      i

    let use_ii_with_poi ii poi =
      let program_order_index = incr poi in
      { ii with A.program_order_index }

    (**************************************************************************)
    (* Values handling                                                        *)
    (**************************************************************************)

    let as_constant = function
      | V.Val c -> c
      | V.Var _ as v ->
          Warn.fatal "Cannot convert value %s into constant" (V.pp_v v)

    let v_unknown_of_type _t = V.fresh_var ()

    let v_of_literal =
      let open AST in
      let open ASLScalar in
      let concrete v = Constant.Concrete v in
      let tr = function
        | L_Int i -> S_Int i |> concrete
        | L_Bool b -> S_Bool b |> concrete
        | L_BitVector bv -> S_BitVector bv |> concrete
        | L_Real _f -> Warn.fatal "Cannot use reals yet."
        | L_String _f -> Warn.fatal "Cannot strings in herd yet."
      in
      fun v -> V.Val (tr v)

    let v_to_int = function
      | V.Val (Constant.Concrete (ASLScalar.S_Int i)) -> Some (Z.to_int i)
      | _ -> None

    let v_as_int = function
      | V.Val (Constant.Concrete i) -> V.Cst.Scalar.to_int i
      | v -> Warn.fatal "Cannot concretise symbolic value: %s" (V.pp_v v)

    let datasize_to_machsize v =
      match v_as_int v with
      | 32 -> MachSize.Word
      | 64 -> MachSize.Quad
      | 128 -> MachSize.S128
      | _ -> Warn.fatal "Cannot access a register with size %s" (V.pp_v v)

    let wrap_op1_symb_as_var op1 = function
      | V.Val (Constant.Symbolic _) as v ->
          let v' = V.fresh_var () in
          M.restrict M.VC.[ Assign (v', Unop (op1, v)) ] >>! v'
      | v -> M.op1 op1 v

    let to_bv = wrap_op1_symb_as_var (Op.ArchOp1 ASLValue.ToBV)
    let to_int_unsigned = wrap_op1_symb_as_var (Op.ArchOp1 ASLValue.ToIntU)
    let to_int_signed = wrap_op1_symb_as_var (Op.ArchOp1 ASLValue.ToIntS)

    (**************************************************************************)
    (* Special monad interations                                              *)
    (**************************************************************************)

    let resize_from_quad = function
      | MachSize.Quad -> return
      | sz -> (
          function
          | V.Val (Constant.Symbolic _) as v -> return v
          | v -> M.op1 (Op.Mask sz) v)

    let write_loc sz loc v ii =
      let* resized_v = resize_from_quad sz v in
      let mk_action loc' = Act.Access (Dir.W, loc', resized_v, sz) in
      M.write_loc mk_action loc ii

    let read_loc sz loc ii =
      let mk_action loc' v' = Act.Access (Dir.R, loc', v', sz) in
      let* v = M.read_loc false mk_action loc ii in
      resize_from_quad sz v >>= to_bv

    (**************************************************************************)
    (* ASL-Backend implementation                                             *)
    (**************************************************************************)

    let choice (m1 : V.v M.t) (m2 : 'b M.t) (m3 : 'b M.t) : 'b M.t =
      M.bind_ctrl_seq_data m1 (function
        | V.Val (Constant.Concrete (ASLScalar.S_Bool b)) -> if b then m2 else m3
        | b ->
            M.bind_ctrl_seq_data (to_int_signed b) (fun v -> M.choiceT v m2 m3))

    let binop =
      let open AST in
      let to_bool op v1 v2 = op v1 v2 >>= M.op1 (Op.ArchOp1 ASLValue.ToBool) in
      let to_bv op v1 v2 = op v1 v2 >>= to_bv in
      let or_ v1 v2 =
        match (v1, v2) with
        | V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)), v
          when Asllib.Bitvector.is_zeros bv ->
            return v
        | v, V.Val (Constant.Concrete (ASLScalar.S_BitVector bv))
          when Asllib.Bitvector.is_zeros bv ->
            return v
        | _ -> to_bv (M.op Op.Or) v1 v2
      in
      function
      | AND -> M.op Op.And |> to_bv
      | BAND -> M.op Op.And
      | BEQ -> M.op Op.Eq |> to_bool
      | BOR -> M.op Op.Or
      | DIV -> M.op Op.Div
      | EOR -> M.op Op.Xor |> to_bv
      | EQ_OP -> M.op Op.Eq |> to_bool
      | GT -> M.op Op.Gt |> to_bool
      | GEQ -> M.op Op.Ge |> to_bool
      | LT -> M.op Op.Lt |> to_bool
      | LEQ -> M.op Op.Le |> to_bool
      | MINUS -> M.op Op.Sub
      | MUL -> M.op Op.Mul
      | NEQ -> M.op Op.Ne |> to_bool
      | OR -> or_
      | PLUS -> M.op Op.Add
      | SHL -> M.op Op.ShiftLeft
      | SHR -> M.op Op.ShiftRight
      | POW | IMPL | MOD | RDIV -> Warn.fatal "Not yet implemented operation."

    let unop op =
      let open AST in
      match op with
      | BNOT -> wrap_op1_symb_as_var (Op.ArchOp1 ASLValue.BoolNot)
      | NEG -> M.op Op.Sub V.zero
      | NOT -> wrap_op1_symb_as_var Op.Inv

    let ternary = function
      | V.Val (Constant.Concrete (ASLScalar.S_Bool true)) -> fun m1 _ -> m1 ()
      | V.Val (Constant.Concrete (ASLScalar.S_Bool false)) -> fun _ m2 -> m2 ()
      | v ->
          fun m1 m2 ->
            let* v1 = m1 () and* v2 = m2 () and* v = to_int_signed v in
            M.op3 Op.If v v1 v2

(* Any access to PSTATE emits an access to NZCV.
 * Notice that the value is casted into an integer.
 *)
    let is_pstate x scope =
      match x,scope with
      | "PSTATE",AST.Scope_Global -> true
      | _ -> false

    let loc_of_scoped_id ii x scope =
      if is_pstate x scope then
        A.Location_reg (ii.A.proc, ASLBase.ArchReg AArch64Base.NZCV)
      else
        A.Location_reg (ii.A.proc, ASLBase.ASLLocalId (scope, x))

    let on_access_identifier  dir (ii,poi) x scope v =
      let loc = loc_of_scoped_id ii x scope in
      let m v =
        let action = Act.Access (dir, loc, v, MachSize.Quad) in
        M.mk_singleton_es action (use_ii_with_poi ii poi) in
      if is_pstate x scope then
        M.op1 (Op.ArchOp1 ASLValue.ToIntU) v >>= m
      else m v

    let on_write_identifier = on_access_identifier Dir.W
    and on_read_identifier =  on_access_identifier Dir.R

    let create_vector li =
      let li = List.map as_constant li in
      return (V.Val (Constant.ConcreteVector li))

    let create_record li =
      let record =
        List.to_seq li
        |> Seq.map (fun (x, v) -> (x, as_constant v))
        |> StringMap.of_seq
      in
      return (V.Val (Constant.ConcreteRecord record))

    let create_exception = create_record
    let freeze = function V.Val c -> V.Val c | V.Var i -> V.Val (V.freeze i)

    let unfreeze = function
      | V.Val (Constant.Frozen i) -> return (V.Var i)
      | v -> return v

    let get_index i v = M.op1 (Op.ArchOp1 (ASLValue.GetIndex i)) v >>= unfreeze

    let set_index i v vec =
      M.op (Op.ArchOp (ASLValue.SetIndex i)) vec (freeze v)

    let get_field name v =
      M.op1 (Op.ArchOp1 (ASLValue.GetField name)) v >>= unfreeze

    let set_field name v record =
      M.op (Op.ArchOp (ASLValue.SetField name)) record (freeze v)

    let read_from_bitvector positions bvs =
      let positions = Asllib.ASTUtils.slices_to_positions v_as_int positions in
      let arch_op1 = ASLValue.BVSlice positions in
      M.op1 (Op.ArchOp1 arch_op1) bvs

    let write_to_bitvector positions w v =
      let positions = Asllib.ASTUtils.slices_to_positions v_as_int positions in
      M.op (Op.ArchOp (ASLValue.BVSliceSet positions)) v w

    let concat_bitvectors bvs =
      let bvs =
        let filter = function
          | V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)) ->
              Asllib.Bitvector.length bv > 0
          | _ -> true
        in
        List.filter filter bvs
      in
      match bvs with
      | [] -> V.Val (Constant.Concrete ASLScalar.empty) |> return
      | [ x ] -> return x
      | h :: t ->
          let folder acc v =
            let* acc = acc in
            M.op (Op.ArchOp ASLValue.Concat) acc v
          in
          List.fold_left folder (return h) t

    (**************************************************************************)
    (* Primitives and helpers                                                 *)
    (**************************************************************************)

    let virtual_to_loc_reg rv ii =
      let i = v_as_int rv in
      if i >= List.length AArch64Base.gprs || i < 0 then
        Warn.fatal "Invalid register number: %d" i
      else
        let arch_reg = AArch64Base.Ireg (List.nth AArch64Base.gprs i) in
        A.Location_reg (ii.A.proc, ASLBase.ArchReg arch_reg)

    let read_register (ii, poi) r_m =
      let* rval = r_m in
      let loc = virtual_to_loc_reg rval ii in
      read_loc MachSize.Quad loc (use_ii_with_poi ii poi)

    let write_register (ii, poi) r_m v_m =
      let* v = v_m >>= to_int_signed and* r = r_m in
      let loc = virtual_to_loc_reg r ii in
      write_loc MachSize.Quad loc v (use_ii_with_poi ii poi) >>! []

    let read_memory (ii, poi) addr_m datasize_m =
      let* addr = addr_m and* datasize = datasize_m in
      let sz = datasize_to_machsize datasize in
      read_loc sz (A.Location_global addr) (use_ii_with_poi ii poi)

    let write_memory (ii, poi) = function
      | [ addr_m; datasize_m; value_m ] ->
          let value_m = M.as_data_port value_m in
          let* addr = addr_m and* datasize = datasize_m and* value = value_m in
          let sz = datasize_to_machsize datasize in
          write_loc sz (A.Location_global addr) value (use_ii_with_poi ii poi)
          >>! []
      | li ->
          Warn.fatal
            "Bad number of arguments passed to write_memory: 3 expected, and \
             only %d provided."
            (List.length li)

    let loc_sp ii = A.Location_reg (ii.A.proc, ASLBase.ArchReg AArch64Base.SP)

    let read_sp (ii, poi) () =
      read_loc MachSize.Quad (loc_sp ii) (use_ii_with_poi ii poi)

    let write_sp (ii, poi) v_m =
      let* v = v_m >>= to_int_signed in
      write_loc MachSize.Quad (loc_sp ii) v (use_ii_with_poi ii poi) >>! []

    let uint bv_m = bv_m >>= to_int_unsigned
    let sint bv_m = bv_m >>= to_int_signed
    let processor_id (ii, _poi) () = return (V.intToV ii.A.proc)

    let can_predict_from v_m w_m =
      let diff_case = v_m in
      let eq_case = M.altT v_m w_m in
      let*| v = v_m and* w = w_m in
      let*| c = M.op Op.Eq v w in
      M.choiceT c eq_case diff_case

    (**************************************************************************)
    (* ASL environment                                                        *)
    (**************************************************************************)

    (* Helpers *)
    let build_primitive name args return_type body =
      let open AST in
      let return_type, make_return_type = return_type in
      let body = SB_Primitive (make_return_type body) in
      let parameters =
        let get_param t =
          match t.desc with
          | T_Bits (BitWidth_SingleExpr { desc = E_Var x; _ }, _) ->
              Some (x, None)
          | _ -> None
        in
        args |> List.filter_map get_param (* |> List.sort String.compare *)
      and args =
        List.mapi (fun i arg_ty -> ("arg_" ^ string_of_int i, arg_ty)) args
      and subprogram_type =
        match return_type with None -> ST_Procedure | _ -> ST_Function
      in
      (D_Func { name; args; body; return_type; parameters; subprogram_type }
      [@warning "-40-42"])

    let arity_zero name return_type f =
      build_primitive name [] return_type @@ function
      | [] -> f ()
      | _ :: _ -> Warn.fatal "Arity error for function %s." name

    let arity_one name args return_type f =
      build_primitive name args return_type @@ function
      | [ x ] -> f x
      | [] | _ :: _ :: _ -> Warn.fatal "Arity error for function %s." name

    let arity_two name args return_type f =
      build_primitive name args return_type @@ function
      | [ x; y ] -> f x y
      | [] | [ _ ] | _ :: _ :: _ :: _ ->
          Warn.fatal "Arity error for function %s." name

    let return_one =
      let make body args = return [ body args ] in
      fun ty -> (Some ty, make)

    let return_zero = (None, Fun.id)

    (* Primitives *)
    let extra_funcs ii_env =
      let open AST in
      let with_pos = Asllib.ASTUtils.add_dummy_pos in
      let here = Asllib.ASTUtils.add_pos_from_pos_of in
      let integer = Asllib.ASTUtils.integer in
      let reg = integer in
      let var x = E_Var x |> with_pos in
      let lit x = E_Literal (L_Int (Z.of_int x)) |> with_pos in
      let bv x = T_Bits (BitWidth_SingleExpr x, []) |> with_pos in
      let bv_var x = bv @@ var x in
      let bv_arg1 = bv_var "arg_1" in
      let bv_N = bv_var "N" in
      let bv_lit x = bv @@ lit x in
      let bv_64 = bv_lit 64 in
      [
        arity_one "read_register" [ reg ] (return_one bv_64)
          (read_register ii_env)
        |> __POS_OF__ |> here;
        arity_two "write_register" [ bv_64; reg ] return_zero
          (write_register ii_env)
        |> __POS_OF__ |> here;
        arity_two "read_memory" [ bv_64 ; integer ]
          (return_one (bv_arg1))
          (read_memory ii_env)
        |> __POS_OF__ |> here;
        build_primitive "write_memory" [ bv_64; integer; bv_arg1 ] return_zero
          (write_memory ii_env)
        |> __POS_OF__ |> here;
        arity_zero "SP_EL0" (return_one bv_64) (read_sp ii_env)
        |> __POS_OF__ |> here;
        arity_one "SP_EL0" [ bv_64 ] return_zero (write_sp ii_env)
        |> __POS_OF__ |> here;
        arity_one "UInt" [ bv_N ] (return_one integer) uint
        |> __POS_OF__ |> here;
        arity_one "SInt" [ bv_N ] (return_one integer) sint
        |> __POS_OF__ |> here;
        arity_zero "ProcessorID" (return_one integer) (processor_id ii_env)
        |> __POS_OF__ |> here;
        arity_two "CanPredictFrom" [ bv_N; bv_N ] (return_one bv_N)
          can_predict_from
        |> __POS_OF__ |> here;
      ]

    (**************************************************************************)
    (* Execution                                                              *)
    (**************************************************************************)

    let build_semantics _t ii =
      let ii_env = (ii, ref ii.A.program_order_index) in
      let module ASLBackend = struct
        type value = V.v
        type 'a m = 'a M.t
        type primitive = value m list -> value m list m
        type ast = primitive AST.t

        let debug_value = V.pp_v
        let is_undetermined = function V.Var _ -> true | V.Val _ -> false
        let v_of_int = V.intToV
        let v_of_literal = v_of_literal
        let v_to_int = v_to_int
        let bind_data = M.( >>= )
        let bind_seq = M.aslseq
        let bind_ctrl = M.bind_ctrl_seq_data
        let prod = M.( >>| )
        let choice = choice
        let delay m k = M.delay_kont "ASL" m k
        let return = M.unitT
        let warnT = M.warnT
        let on_write_identifier = on_write_identifier ii_env
        let on_read_identifier = on_read_identifier ii_env
        let binop = binop
        let unop = unop
        let ternary = ternary
        let create_vector = create_vector
        let create_record = create_record
        let create_exception = create_exception
        let get_index = get_index
        let set_index = set_index
        let get_field = get_field
        let set_field = set_field
        let read_from_bitvector = read_from_bitvector
        let write_to_bitvector = write_to_bitvector
        let concat_bitvectors = concat_bitvectors
        let v_unknown_of_type = v_unknown_of_type
      end in
      let module Config = struct
        let type_checking_strictness : Asllib.Typing.strictness =
          if C.variant (Variant.ASLType `Warn) then `Warn
          else if C.variant (Variant.ASLType `TypeCheck) then `TypeCheck
          else `Silence

        let unroll =
          match C.unroll with None -> Opts.unroll_default `ASL | Some u -> u

        module Instr = Asllib.Instrumentation.NoInstr
      end in
      let module ASLInterpreter = Asllib.Interpreter.Make (ASLBackend) (Config)
      in
      let inst = Asllib.ASTUtils.no_primitive ii.A.inst in
      let ast =
        let ( @! ) = List.rev_append in
        if C.variant Variant.ASL_AArch64 then
          let build ?ast_type version fname =
            Filename.concat "asl-pseudocode" fname
            |> C.libfind
            |> ASLBase.build_ast_from_file ?ast_type version
            |> Asllib.ASTUtils.no_primitive
          in
          let patches =
            let open  AST in
            let patches = build `ASLv1 "patches.asl" in
            (* Patch "patches.asl":
             * replace the default initial value of "PSTATE"
             * by the value transmitted in the env field of
             * the instruction instance ii.
             *)
            List.map
              (fun d ->
                match d.desc with
                |  D_GlobalStorage ({ name="PSTATE"; _ } as desc) ->
                    begin
                      let to_d v =
                        let v = Asllib.ASTUtils.add_dummy_pos v in
                        let desc = { desc with initial_value= Some v; } in
                        { d with desc=D_GlobalStorage desc;} in
                      match
                        A.look_reg
                          (ASLBase.ASLLocalId (Scope_Global,"PSTATE"))
                          ii.A.env.A.regs
                      with
                      | Some (A.V.Val (Constant.Concrete c)) ->
                         begin match c with
                         | ASLScalar.S_Int i ->
                            let bv = Asllib.Bitvector.of_z 64 i in
                            let v = E_Literal (L_BitVector bv) in
                            to_d v
                         | _ ->
                            Warn.fatal
                              "Unexpected initial value for PSTATE: %s"
                              (ASLScalar.pp C.PC.hexa c)
                         end
                      | Some v ->
                         Warn.fatal
                           "Unexpected initial value for PSTATE: %s"
                           (A.V.pp C.PC.hexa v)
                      | None ->
                         d
                    end
                | _ -> d)
              patches
          and custom_implems = build `ASLv1 "implementations.asl"
          and shared = build `ASLv0 "shared_pseudocode.asl" in
          let shared =
            (List.filter
               AST.(
                 fun d ->
                   match d.desc with
                   | D_Func { name = "Zeros" | "Ones" | "Replicate"; _ } ->
                       false
                   | _ -> true)
               shared [@warning "-40-42"])
          in
          let shared =
            Asllib.ASTUtils.patch
              ~patches:(custom_implems @! patches @! extra_funcs ii_env)
              ~src:shared
          in
          inst @! shared
        else inst @! extra_funcs ii_env
      in
      let () =
        if false then Format.eprintf "Completed AST: %a.@." Asllib.PP.pp_t ast
      in
      let exec () = ASLInterpreter.run ast in
      let* i =
        match Asllib.Error.intercept exec () with
        | Ok m -> m
        | Error err -> Asllib.Error.error_to_string err |> Warn.fatal "%s"
      in
      assert (V.equal i V.zero);
      M.addT !(snd ii_env) B.nextT

    let spurious_setaf _ = assert false
  end
end
