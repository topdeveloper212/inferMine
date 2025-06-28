(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type t =
  | AnnotMap
  | BufferOverrunAnalysis
  | BufferOverrunChecker
  | ConfigImpactAnalysis
  | Cost
  | DisjunctiveDemo
  | StaticConstructorStallChecker
  | LabResourceLeaks
  | LithoRequiredProps
  | Pulse
  | Purity
  | RacerD
  | ScopeLeakage
  | SIOF
  | Lineage
  | LineageShape
  | Starvation
[@@deriving compare, equal, hash, show, variants]

let database_fields = List.map ~f:fst Variants.descriptions

let to_checker payload_id : Checker.t =
  match payload_id with
  | AnnotMap ->
      AnnotationReachability
  | BufferOverrunAnalysis ->
      BufferOverrunAnalysis
  | BufferOverrunChecker ->
      BufferOverrunChecker
  | ConfigImpactAnalysis ->
      ConfigImpactAnalysis
  | Cost ->
      Cost
  | DisjunctiveDemo ->
      DisjunctiveDemo
  | StaticConstructorStallChecker ->
      StaticConstructorStallChecker
  | LabResourceLeaks ->
      ResourceLeakLabExercise
  | LithoRequiredProps ->
      LithoRequiredProps
  | Pulse ->
      Pulse
  | Purity ->
      PurityAnalysis
  | RacerD ->
      RacerD
  | ScopeLeakage ->
      ScopeLeakage
  | SIOF ->
      SIOF
  | Lineage ->
      Lineage
  | LineageShape ->
      LineageShape
  | Starvation ->
      Starvation
