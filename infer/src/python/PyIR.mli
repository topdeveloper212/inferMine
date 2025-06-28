(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

module Location : sig
  type t

  val line : t -> int option

  val pp : Format.formatter -> t -> unit
end

module Error : sig
  type kind

  type t = Logging.error * Location.t * kind

  val pp_kind : Format.formatter -> kind -> unit
end

module NodeName : sig
  type t [@@deriving equal]

  module Map : Stdlib.Map.S with type key = t

  val pp : Format.formatter -> t -> unit
end

module SSA : sig
  type t

  val id : t -> int

  val pp : Format.formatter -> t -> unit

  module Hashtbl : Stdlib.Hashtbl.S with type key = t

  module Map : Stdlib.Map.S with type key = t
end

module Ident : sig
  type t [@@deriving compare]

  val mk : string -> t

  val pp : Format.formatter -> t -> unit

  val to_textual_base_type_name : t -> Textual.BaseTypeName.t

  module Hashtbl : Stdlib.Hashtbl.S with type key = t

  module Special : sig
    val name : t

    val print : t
  end
end

module ScopedIdent : sig
  type scope = Global | Fast | Name

  type t = {scope: scope; ident: Ident.t}
end

module QualName : sig
  type t = {module_name: Ident.t; function_name: Ident.t}

  val pp : Format.formatter -> t -> unit

  module Map : Stdlib.Map.S with type key = t
end

module UnaryOp : sig
  type t = Positive | Negative | Not | Invert
end

module BinaryOp : sig
  type t =
    | Add
    | And
    | FloorDivide
    | LShift
    | MatrixMultiply
    | Modulo
    | Multiply
    | Or
    | Power
    | RShift
    | Subtract
    | TrueDivide
    | Xor
end

module CompareOp : sig
  type t = Lt | Le | Eq | Neq | Gt | Ge | In | NotIn | Is | IsNot | Exception | BAD
end

module FormatFunction : sig
  type t = Str | Repr | Ascii
end

module BuiltinCaller : sig
  type unary_intrinsics =
    | PrintExpr
    | ImportStar
    | StopiterationError
    | AsyncGenValueWrapperNew
    | UnaryPos
    | ListToTuple
    | MakeTypevar
    | MakeParamspec
    | MakeTypevartuple
    | SubscriptGeneric
    | MakeTypealias

  type binary_intrinsics =
    | PrepReraiseStar
    | TypevarWithBound
    | TypevarWithConstraints
    | SetFunctionTypeParams

  type t =
    | BuildClass
    | Format
    | FormatFn of FormatFunction.t
    | Inplace of BinaryOp.t
    | Binary of BinaryOp.t
    | BinarySlice
    | Unary of UnaryOp.t
    | Compare of CompareOp.t
    | GetAIter
    | GetIter
    | NextIter
    | HasNextIter
    | IterData
    | GetYieldFromIter
    | ListAppend
    | ListExtend
    | ListToTuple
    | SetAdd
    | SetUpdate
    | DictSetItem
    | DictUpdate
    | DictMerge
    | DeleteSubscr
    | YieldFrom
    | GetAwaitable
    | UnpackEx
    | GetPreviousException
    | UnaryIntrinsic of unary_intrinsics
    | BinaryIntrinsic of binary_intrinsics
end

module Const : sig
  type t =
    | Bool of bool
    | Int of Z.t
    | Float of float
    | Complex of {real: float; imag: float}
    | String of string
    | InvalidUnicode
    | Bytes of bytes
    | None
end

module Exp : sig
  type collection = List | Set | Tuple | Map

  type t =
    | AssertionError
    | BuildFrozenSet of t list
    | BuildSlice of t list
    | BuildString of t list
    | Collection of {kind: collection; values: t list; unpack: bool}
    | Const of Const.t
    | Function of
        { qual_name: QualName.t
        ; default_values: t
        ; default_values_kw: t
        ; annotations: t
        ; cells_for_closure: t }
    | GetAttr of {exp: t; attr: Ident.t}
    | ImportFrom of {name: Ident.t; exp: t}
    | ImportName of {name: Ident.t; fromlist: t; level: t}
    | LoadClassDeref of {name: Ident.t; slot: int}  (** [LOAD_CLASSDEREF] *)
    | LoadClosure of {name: Ident.t; slot: int}  (** [LOAD_CLOSURE] *)
    | LoadDeref of {name: Ident.t; slot: int}  (** [LOAD_DEREF] *)
    | LoadFastCheck of {name: Ident.t}  (** [LOAD_FAST_CHECK] *)
    | LoadFastAndClear of {name: Ident.t}  (** [LOAD_FAST_AND_CLEAR] *)
    | LoadLocals  (** [LOAD_LOCALS] *)
    | LoadFromDictOrDeref of {slot: int; mapping: t}  (** [LOAD_FROM_DICT_OR_DEREF] *)
    | LoadSuperAttr of {attr: Ident.t; super: t; class_: t; self: t}  (** [LOAD_SUPER_ATTR] *)
    | MatchClass of {subject: t; type_: t; count: int; names: t}
    | BoolOfMatchClass of t
    | AttributesOfMatchClass of t
    | MatchSequence of t
    | GetLen of t
    | Subscript of {exp: t; index: t}
    | Temp of SSA.t
    | Var of ScopedIdent.t

  val pp : Format.formatter -> t -> unit
end

module Stmt : sig
  type gen_kind = Generator | Coroutine | AsyncGenerator

  type t =
    | Let of {lhs: SSA.t; rhs: Exp.t}
    | SetAttr of {lhs: Exp.t; attr: Ident.t; rhs: Exp.t}
    | Store of {lhs: ScopedIdent.t; rhs: Exp.t}
    | StoreSlice of {container: Exp.t; start: Exp.t; end_: Exp.t; rhs: Exp.t}
    | StoreSubscript of {lhs: Exp.t; index: Exp.t; rhs: Exp.t}
    | Call of {lhs: SSA.t; exp: Exp.t; args: Exp.t list; arg_names: Exp.t}
    | CallEx of {lhs: SSA.t; exp: Exp.t; kargs: Exp.t; arg_names: Exp.t}
    | CallMethod of
        {lhs: SSA.t; name: Ident.t; self_if_needed: Exp.t; args: Exp.t list; arg_names: Exp.t}
    | BuiltinCall of {lhs: SSA.t; call: BuiltinCaller.t; args: Exp.t list; arg_names: Exp.t}
    | StoreDeref of {name: Ident.t; slot: int; rhs: Exp.t}  (** [STORE_DEREF] *)
    | Delete of ScopedIdent.t
    | DeleteDeref of {name: Ident.t; slot: int}  (** [DELETE_DEREF] *)
    | DeleteAttr of {exp: Exp.t; attr: Ident.t}
    | MakeCell of int  (** [MAKE_CELL] *)
    | CopyFreeVars of int  (** [COPY_FREE_VARS] *)
    | ImportStar of Exp.t
    | GenStart of {kind: gen_kind}
    | SetupAnnotations
    | Yield of {lhs: SSA.t; rhs: Exp.t}
end

module Terminator : sig
  type node_call = {label: NodeName.t; ssa_args: Exp.t list}

  type t =
    | Return of Exp.t
    | Jump of node_call
    | If of {exp: Exp.t; then_: node_call; else_: node_call}
    | Throw of Exp.t
end

module Node : sig
  type t =
    { name: NodeName.t
    ; first_loc: Location.t
    ; last_loc: Location.t
    ; ssa_parameters: SSA.t list
    ; stmts: (Location.t * Stmt.t) list
    ; last: Terminator.t }
end

module CodeInfo : sig
  type t =
    { co_name: Ident.t
    ; co_firstlineno: int
    ; co_nlocals: int
    ; co_argcount: int
    ; co_posonlyargcount: int
    ; co_kwonlyargcount: int
    ; co_cellvars: Ident.t array
    ; co_freevars: Ident.t array
    ; co_names: Ident.t array
    ; co_varnames: Ident.t array
    ; has_star_arguments: bool
    ; has_star_keywords: bool
    ; is_async: bool
    ; is_generator: bool }
end

module CFG : sig
  type t = {entry: NodeName.t; nodes: Node.t NodeName.Map.t; code_info: CodeInfo.t}
end

module Module : sig
  type stats = {count_imported_modules: int}

  type t = {name: Ident.t; toplevel: CFG.t; functions: CFG.t QualName.Map.t; stats: stats}

  val pp : Format.formatter -> t -> unit [@@warning "-unused-value-declaration"]
end

val mk : debug:bool -> path_prefix:string option -> FFI.Code.t -> (Module.t, Error.t) result

val test :
  ?filename:string -> ?debug:bool -> ?run:(Module.t -> unit) -> ?show:bool -> string -> unit
[@@warning "-unused-value-declaration"]
(* takes a Python source program as string argument, convert it into PyIR and executes [run] on the result
   (or print the result if [run] is not given and [show] is true) *)

val test_files : ?debug:bool -> ?run:(Module.t list -> unit) -> (string * string) list -> unit
[@@warning "-unused-value-declaration"]
(* same as [test] but on a collection of module string representation. The input is a list of (filename, source) pairs *)

val test_cfg_skeleton : ?filename:string -> ?show:bool -> string -> unit
[@@warning "-unused-value-declaration"]
