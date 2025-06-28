/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
class A {}

// TypeFilter.topl says this is bad, as is everything that extends it.
class B {}

class C extends B {}

class D extends C {}

class E extends A {}

class LongBadName {}

public class TypeFilter {
  static void f(Object x) {}

  static void aOk(A x) {
    f(x);
  }

  static void bBad(B x) {
    f(x);
  }

  static void cBad(C x) {
    f(x);
  }

  static void dBad(D x) {
    f(x);
  }

  static void eOk(E x) {
    f(x);
  }

  static void longArgBad(LongBadName x) {
    f(x);
  }

  static void longLocalBad() {
    f(new B());
  }

  // Should fail ReturnB and ReturnNotC
  // TODO: Tests do not record which TOPL property fails.
  static void fBad() {
    mk_b();
  }

  // Should fail ReturnB and ReturnC
  static void gBad() {
    mk_c();
  }

  // helper
  static B mk_b() {
    return new B();
  }

  // helper
  static C mk_c() {
    return new C();
  }
}
