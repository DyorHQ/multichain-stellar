//! Checked fixed-point maths (DESIGN-stellar-contracts-v2 §4). Amounts are never negative: every function takes
//! `a, b ≥ 0` and `c > 0` and traps otherwise, as it traps on overflow (overflow-checks are on in every profile).

use soroban_sdk::{Env, U256};

/// floor(a · b / c), with an i128 intermediate (as v1's curve.rs).
pub fn mul_div(a: i128, b: i128, c: i128) -> i128 {
    check_operands(a, b, c);
    a.checked_mul(b).expect("mul overflow") / c
}

/// ceil(a · b / c), with an i128 intermediate.
pub fn mul_div_up(a: i128, b: i128, c: i128) -> i128 {
    check_operands(a, b, c);
    let p = a.checked_mul(b).expect("mul overflow");
    let q = p / c;
    if p % c == 0 {
        q
    } else {
        q + 1
    }
}

/// floor(a · b / c) with a U256 intermediate, so `a · b` may exceed i128. Traps when the result does.
pub fn mul_div_u256(e: &Env, a: i128, b: i128, c: i128) -> i128 {
    check_operands(a, b, c);
    to_i128(product(e, a, b).div(&u256(e, c)))
}

/// ceil(a · b / c) with a U256 intermediate. Traps when the result exceeds i128.
pub fn mul_div_up_u256(e: &Env, a: i128, b: i128, c: i128) -> i128 {
    check_operands(a, b, c);
    let c = u256(e, c);
    // a · b < 2^254 and c < 2^127, so a · b + c − 1 stays inside U256.
    to_i128(product(e, a, b).add(&c).sub(&U256::from_u32(e, 1)).div(&c))
}

/// floor(√n).
pub fn isqrt_u128(n: u128) -> u128 {
    if n < 2 {
        return n;
    }
    // Newton's method from above: x0 = 2^⌈bits/2⌉ > √n, and each step stays ≥ ⌊√n⌋ until it stops decreasing.
    let bits = 128 - n.leading_zeros();
    let mut x = 1u128 << bits.div_ceil(2);
    loop {
        let y = (x + n / x) >> 1;
        if y >= x {
            return x;
        }
        x = y;
    }
}

fn check_operands(a: i128, b: i128, c: i128) {
    assert!(a >= 0 && b >= 0, "negative operand");
    assert!(c > 0, "non-positive divisor");
}

fn u256(e: &Env, v: i128) -> U256 {
    U256::from_u128(e, v as u128)
}

fn product(e: &Env, a: i128, b: i128) -> U256 {
    u256(e, a).mul(&u256(e, b))
}

fn to_i128(v: U256) -> i128 {
    v.to_u128().and_then(|v| i128::try_from(v).ok()).expect("result exceeds i128")
}

#[cfg(test)]
mod test {
    extern crate std;

    use super::*;
    use core::cell::Cell;
    use ethnum::U256 as RefU256;
    use proptest::prelude::*;
    use proptest::test_runner::{Config, TestRunner};
    use std::panic::{catch_unwind, AssertUnwindSafe};

    fn env() -> Env {
        let e = Env::default();
        e.cost_estimate().budget().reset_unlimited();
        e
    }

    // ---------------------------------------------------------------------------------------------- i128 forms

    #[test]
    fn mul_div_rounds_down_and_mul_div_up_rounds_up() {
        assert_eq!(mul_div(7, 3, 2), 10);
        assert_eq!(mul_div_up(7, 3, 2), 11);
        assert_eq!(mul_div(1, 1, 3), 0);
        assert_eq!(mul_div_up(1, 1, 3), 1);
        // Exact quotients don't round either way.
        assert_eq!(mul_div(6, 4, 3), 8);
        assert_eq!(mul_div_up(6, 4, 3), 8);
        assert_eq!(mul_div(0, 5, 7), 0);
        assert_eq!(mul_div_up(0, 5, 7), 0);
        // The largest product that fits.
        assert_eq!(mul_div(i128::MAX, 1, 1), i128::MAX);
        assert_eq!(mul_div_up(i128::MAX, 1, 2), i128::MAX / 2 + 1);
    }

    #[test]
    #[should_panic(expected = "mul overflow")]
    fn mul_div_traps_on_overflow() {
        mul_div(i128::MAX, 2, 4);
    }

    #[test]
    #[should_panic(expected = "mul overflow")]
    fn mul_div_up_traps_on_overflow() {
        mul_div_up(1 << 64, 1 << 63, 1);
    }

    #[test]
    #[should_panic(expected = "non-positive divisor")]
    fn mul_div_traps_on_zero_divisor() {
        mul_div(1, 1, 0);
    }

    #[test]
    #[should_panic(expected = "negative operand")]
    fn mul_div_up_traps_on_negative_operand() {
        mul_div_up(-3, 1, 2);
    }

    // ---------------------------------------------------------------------------------------------- U256 forms

    #[test]
    fn u256_forms_round_like_the_i128_forms() {
        let e = env();
        assert_eq!(mul_div_u256(&e, 7, 3, 2), 10);
        assert_eq!(mul_div_up_u256(&e, 7, 3, 2), 11);
        assert_eq!(mul_div_u256(&e, 6, 4, 3), 8);
        assert_eq!(mul_div_up_u256(&e, 6, 4, 3), 8);
        assert_eq!(mul_div_u256(&e, 0, 9, 4), 0);
        assert_eq!(mul_div_up_u256(&e, 0, 9, 4), 0);
        assert_eq!(mul_div_up_u256(&e, 1, 1, i128::MAX), 1);
    }

    #[test]
    fn u256_forms_handle_products_beyond_i128() {
        let e = env();
        // 2^100 · 2^100 / 2^90 = 2^110, exact.
        assert_eq!(mul_div_u256(&e, 1 << 100, 1 << 100, 1 << 90), 1 << 110);
        assert_eq!(mul_div_up_u256(&e, 1 << 100, 1 << 100, 1 << 90), 1 << 110);
        // (2^127 − 1)^2 / (2^127 − 1) = 2^127 − 1: the largest result that fits.
        assert_eq!(mul_div_u256(&e, i128::MAX, i128::MAX, i128::MAX), i128::MAX);
        assert_eq!(mul_div_up_u256(&e, i128::MAX, i128::MAX, i128::MAX), i128::MAX);
        // Rounding with a remainder: (2^100 + 1) · 2^100 / 2^101 = 2^99 + 1/2.
        assert_eq!(mul_div_u256(&e, (1 << 100) + 1, 1 << 100, 1 << 101), 1 << 99);
        assert_eq!(mul_div_up_u256(&e, (1 << 100) + 1, 1 << 100, 1 << 101), (1 << 99) + 1);
    }

    #[test]
    #[should_panic(expected = "result exceeds i128")]
    fn mul_div_u256_traps_when_the_result_exceeds_i128() {
        mul_div_u256(&env(), i128::MAX, 2, 1);
    }

    #[test]
    #[should_panic(expected = "result exceeds i128")]
    fn mul_div_up_u256_traps_when_only_the_rounding_exceeds_i128() {
        // (2^64 − 1)(2^64 + 1) / 2 = 2^127 − 1/2: the floor is i128::MAX, the ceiling one past it.
        let e = env();
        assert_eq!(mul_div_u256(&e, (1 << 64) - 1, (1 << 64) + 1, 2), i128::MAX);
        mul_div_up_u256(&e, (1 << 64) - 1, (1 << 64) + 1, 2);
    }

    #[test]
    #[should_panic(expected = "negative operand")]
    fn mul_div_u256_traps_on_negative_operand() {
        mul_div_u256(&env(), 1, -1, 1);
    }

    #[test]
    #[should_panic(expected = "non-positive divisor")]
    fn mul_div_up_u256_traps_on_zero_divisor() {
        mul_div_up_u256(&env(), 1, 1, 0);
    }

    fn runner(cases: u32) -> TestRunner {
        TestRunner::new(Config { cases, failure_persistence: None, ..Config::default() })
    }

    fn reference(a: i128, b: i128, c: i128, up: bool) -> Option<i128> {
        let p = RefU256::from(a as u128) * RefU256::from(b as u128);
        let c = RefU256::from(c as u128);
        let q = if up { (p + c - 1) / c } else { p / c };
        i128::try_from(q).ok()
    }

    /// Values spread over every magnitude: dust, typical amounts and values near i128::MAX.
    fn magnitudes(min: i128) -> impl Strategy<Value = i128> {
        prop_oneof![min..=1_000i128, min..=(1i128 << 64), min..=i128::MAX]
    }

    #[test]
    fn u256_forms_match_a_reference_on_10_000_random_inputs() {
        let e = env();
        let (fits, traps) = (Cell::new(0u32), Cell::new(0u32));
        // Expected traps are caught below; keep their messages out of the test output.
        let hook = std::panic::take_hook();
        std::panic::set_hook(std::boxed::Box::new(|_| {}));
        let result = runner(10_000).run(&(magnitudes(0), magnitudes(0), magnitudes(1)), |(a, b, c)| {
            for up in [false, true] {
                let expected = reference(a, b, c, up);
                let got = catch_unwind(AssertUnwindSafe(|| {
                    if up {
                        mul_div_up_u256(&e, a, b, c)
                    } else {
                        mul_div_u256(&e, a, b, c)
                    }
                }))
                .ok();
                // None on both sides: the result exceeds i128 and the call trapped.
                prop_assert_eq!(got, expected, "a={} b={} c={} up={}", a, b, c, up);
                let counter = if expected.is_some() { &fits } else { &traps };
                counter.set(counter.get() + 1);
            }
            Ok(())
        });
        std::panic::set_hook(hook);
        result.unwrap();
        // Both outcomes were exercised.
        assert!(fits.get() > 1_000 && traps.get() > 100, "fits {} traps {}", fits.get(), traps.get());
    }

    #[test]
    fn i128_forms_match_the_u256_forms_wherever_the_product_fits() {
        let e = env();
        runner(2_000)
            .run(&(0..=(1i128 << 63), 0..=(1i128 << 63), 1..=i128::MAX), |(a, b, c)| {
                prop_assert_eq!(mul_div(a, b, c), mul_div_u256(&e, a, b, c));
                prop_assert_eq!(mul_div_up(a, b, c), mul_div_up_u256(&e, a, b, c));
                Ok(())
            })
            .unwrap();
    }

    // ---------------------------------------------------------------------------------------------- isqrt

    #[test]
    fn isqrt_is_exact_on_perfect_squares_and_correct_next_to_them() {
        let roots = [
            0u128,
            1,
            2,
            3,
            10,
            1_000,
            31_622,
            1 << 32,
            (1 << 32) + 7,
            3_037_000_499,
            (1 << 63) + 1,
            u64::MAX as u128,
        ];
        for r in roots {
            let n = r * r;
            assert_eq!(isqrt_u128(n), r, "√{n}");
            if n > 0 {
                assert_eq!(isqrt_u128(n - 1), r - 1, "√({n} − 1)");
            }
            assert_eq!(isqrt_u128(n + 1), if r == 0 { 1 } else { r }, "√({n} + 1)");
        }
        assert_eq!(isqrt_u128(u128::MAX), u64::MAX as u128);
    }

    #[test]
    fn isqrt_is_the_floor_on_random_inputs() {
        runner(10_000)
            .run(&prop_oneof![0..=1_000_000u128, any::<u128>()], |n| {
                let r = isqrt_u128(n);
                prop_assert!(r * r <= n);
                // (r + 1)^2 > n, written so it can't overflow when r = 2^64 − 1.
                prop_assert!(r == u64::MAX as u128 || (r + 1) * (r + 1) > n);
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn isqrt_matches_the_reference_on_squares_of_random_roots() {
        runner(2_000)
            .run(&(0..=u64::MAX as u128), |r| {
                let n = r * r;
                prop_assert_eq!(isqrt_u128(n), r);
                if n > 0 {
                    prop_assert_eq!(isqrt_u128(n - 1), r - 1);
                }
                if n < u128::MAX {
                    prop_assert_eq!(isqrt_u128(n + 1), r.max(1));
                }
                Ok(())
            })
            .unwrap();
    }
}
