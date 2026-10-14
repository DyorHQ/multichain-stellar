//! dyor-common: what the DyorHQ v2 contracts share (DESIGN-stellar-contracts-v2 §4).
//!
//! - [`types`]: the types that cross contract boundaries (venues, graduation arguments and results, harvest payees,
//!   position references, durations, TTL policy, recorded failures).
//! - [`durations`]: duration bounds, the production and testnet-qa sets of §14.3, and the rules both constructors
//!   check.
//! - [`clients`]: `#[contractclient]` traits for every cross-contract call; [`aquarius`] holds the Aquarius ones and
//!   CT-03's gate flags.
//! - [`math`]: checked `mul_div` forms (i128 and U256 intermediates) and `isqrt_u128`.
//! - [`ttl`]: TTL policy validation and the persistent-entry bump.
//! - This module: shared constants and the error namespaces (finding V10).
//!
//! It is a plain library, not a contract. No contract crate depends on another contract crate: what two contracts
//! must agree on lives here.
#![no_std]

pub mod aquarius;
pub mod clients;
pub mod durations;
pub mod math;
pub mod ttl;
pub mod types;

pub use clients::*;
pub use durations::*;
pub use math::*;
pub use ttl::*;
pub use types::*;

use soroban_sdk::xdr::{ScErrorCode, ScErrorType};
use soroban_sdk::{Error, InvokeError};

/// 100% in basis points.
pub const BPS: u32 = 10_000;
/// The most of each asset an executor may leave unused at graduation (§5.5, §12).
pub const GRAD_DUST_BPS: u32 = 1;
/// The most one harvest round takes, as a share of the position's value (§8.2).
pub const MAX_HARVEST_ROUND_BPS: u32 = 50;
/// Soroswap's minimum-liquidity lock (UniswapV2's value); CT-02 confirms it against the pair fixture.
pub const SOROSWAP_MIN_LIQ: i128 = 1_000;

// ------------------------------------------------------------------------------------------------ error namespaces

/// Every v2 `#[contracterror]` value is `ERR_BASE + tag·100 + n`, where `n` (1–99) is the code in that contract's
/// table. A sub-call's error reaches a `try_` caller without the address that raised it; the namespace says which
/// contract it was (V10).
pub const ERR_BASE: u32 = 10_000;
pub const TAG_LAUNCHPAD_V2: u32 = 1;
pub const TAG_LAUNCH_TOKEN_V2: u32 = 2;
pub const TAG_EXEC_SOROSWAP: u32 = 3;
pub const TAG_EXEC_AQUARIUS: u32 = 4;
pub const TAG_QA_EXEC_FAIL: u32 = 5;
pub const TAG_LP_LOCKER: u32 = 6;
pub const TAG_MOMENTS_V2: u32 = 7;
pub const TAG_MOMENT_NFT: u32 = 8;
pub const TAG_MOMENT_COIN: u32 = 9;
pub const TAG_MOMENTS_GRADUATOR: u32 = 10;
/// Every tag, in order.
pub const TAGS: [u32; 10] = [
    TAG_LAUNCHPAD_V2,
    TAG_LAUNCH_TOKEN_V2,
    TAG_EXEC_SOROSWAP,
    TAG_EXEC_AQUARIUS,
    TAG_QA_EXEC_FAIL,
    TAG_LP_LOCKER,
    TAG_MOMENTS_V2,
    TAG_MOMENT_NFT,
    TAG_MOMENT_COIN,
    TAG_MOMENTS_GRADUATOR,
];
/// The namespaced range, 10_100–11_099: outside OpenZeppelin's codes (100–1501) and the Soroswap fixtures' codes.
pub const ERR_MIN: u32 = ERR_BASE + 100;
pub const ERR_MAX: u32 = ERR_BASE + 1_099;
/// `GradFailure::origin` of a contract error outside the DyorHQ namespace (a DEX, a SAC, an OpenZeppelin check).
pub const ORIGIN_FOREIGN: u32 = 0;
/// `GradFailure::origin` of a host error; its code is the `ScErrorCode`.
pub const ORIGIN_HOST: u32 = 99;

/// The on-chain value of local error `n` (1–99) of the contract tagged `tag`. A bad tag or `n` fails to compile
/// in a const context.
pub const fn err_code(tag: u32, n: u32) -> u32 {
    assert!(tag >= TAG_LAUNCHPAD_V2 && tag <= TAG_MOMENTS_GRADUATOR, "unknown contract tag");
    assert!(n >= 1 && n <= 99, "local error code outside 1..=99");
    ERR_BASE + tag * 100 + n
}

/// The tag whose namespace holds `code`, if any.
pub const fn tag_of(code: u32) -> Option<u32> {
    if code >= ERR_MIN && code <= ERR_MAX {
        Some((code - ERR_BASE) / 100)
    } else {
        None
    }
}

/// Checks at compile time that a `#[contracterror]` enum's values are `err_code(tag, n)`. `#[contracterror]` takes
/// integer literals only, so a contract writes the on-chain value and pairs each variant with its local code:
///
/// ```ignore
/// #[contracterror]
/// #[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
/// #[repr(u32)]
/// pub enum Error {
///     NotCaller = 10_301,
///     InvalidAmounts = 10_302,
/// }
/// dyor_common::assert_err_codes!(dyor_common::TAG_EXEC_SOROSWAP; Error::NotCaller = 1, Error::InvalidAmounts = 2);
/// ```
#[macro_export]
macro_rules! assert_err_codes {
    ($tag:expr; $($variant:path = $n:literal),+ $(,)?) => {
        const _: () = {
            $( assert!($variant as u32 == $crate::err_code($tag, $n), "error value outside its namespace"); )+
        };
    };
}

/// Decodes the error of a `try_` call into an `Executor` or a `Graduator` (the outer `Err` of `try_graduate`):
/// - a contract error in 10_100–11_099: origin = its tag, code as raised;
/// - any other contract error (a DEX, a SAC, an OpenZeppelin check): origin `ORIGIN_FOREIGN`, the raw code;
/// - a host error: origin `ORIGIN_HOST`, its `ScErrorCode`.
///
/// Both traits declare `soroban_sdk::Error` as their error type, so the error always arrives as `Ok(error)` with its
/// code intact. `InvokeError::Abort` only comes from a client with a narrower error type, which has already dropped
/// the host's code; it is reported as a host `InternalError`.
pub fn grad_failure(err: Result<Error, InvokeError>) -> GradFailure {
    match err {
        Ok(e) if e.is_type(ScErrorType::Contract) => contract_failure(e.get_code()),
        Ok(e) => GradFailure { origin: ORIGIN_HOST, code: e.get_code() },
        Err(InvokeError::Contract(code)) => contract_failure(code),
        Err(InvokeError::Abort) => GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InternalError as u32 },
    }
}

fn contract_failure(code: u32) -> GradFailure {
    GradFailure { origin: tag_of(code).unwrap_or(ORIGIN_FOREIGN), code }
}

#[cfg(test)]
mod test {
    extern crate std;

    use super::*;
    use soroban_sdk::testutils::Address as _;
    use soroban_sdk::{contract, contracterror, contractimpl, panic_with_error, Address, Env, String};

    // ---------------------------------------------------------------------------------------------- err_code

    #[test]
    fn err_code_is_base_plus_tag_times_100_plus_n() {
        for tag in TAGS {
            for n in 1..=99 {
                assert_eq!(err_code(tag, n), ERR_BASE + tag * 100 + n);
            }
        }
        // The spec's examples (§4, §5.7, §7, §12).
        assert_eq!(err_code(TAG_EXEC_SOROSWAP, 3), 10_303);
        assert_eq!(err_code(TAG_EXEC_AQUARIUS, 4), 10_404);
        assert_eq!(err_code(TAG_EXEC_AQUARIUS, 5), 10_405);
        assert_eq!(err_code(TAG_QA_EXEC_FAIL, 2), 10_502);
        assert_eq!(err_code(TAG_LAUNCHPAD_V2, 34), 10_134);
        assert_eq!(err_code(TAG_LAUNCHPAD_V2, 37), 10_137);
        assert_eq!(err_code(TAG_MOMENTS_GRADUATOR, 3), 11_003);
    }

    #[test]
    fn tags_are_the_ten_contracts_in_order() {
        assert_eq!(TAGS, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        assert!(!TAGS.contains(&ORIGIN_FOREIGN) && !TAGS.contains(&ORIGIN_HOST));
    }

    #[test]
    fn tag_ranges_are_disjoint_inside_the_namespace_and_clear_of_openzeppelin() {
        let ranges: std::vec::Vec<(u32, u32)> = TAGS.iter().map(|&t| (err_code(t, 1), err_code(t, 99))).collect();
        for (i, &(lo, hi)) in ranges.iter().enumerate() {
            assert!(ERR_MIN <= lo && hi <= ERR_MAX, "tag {} inside 10_100–11_099", i + 1);
            // OpenZeppelin stellar-tokens and stellar-contract-utils 0.7.2 use 100–1501.
            assert!(lo > 1_501, "tag {} clear of OpenZeppelin's codes", i + 1);
            for &(lo2, hi2) in &ranges[i + 1..] {
                assert!(hi < lo2 || hi2 < lo, "ranges overlap");
            }
        }
        assert_eq!((ERR_MIN, ERR_MAX), (10_100, 11_099));
    }

    #[test]
    #[should_panic(expected = "unknown contract tag")]
    fn err_code_refuses_an_unknown_tag() {
        err_code(11, 1);
    }

    #[test]
    #[should_panic(expected = "local error code outside 1..=99")]
    fn err_code_refuses_a_local_code_of_100() {
        err_code(TAG_LP_LOCKER, 100);
    }

    #[test]
    fn tag_of_inverts_err_code() {
        for tag in TAGS {
            for n in 1..=99 {
                assert_eq!(tag_of(err_code(tag, n)), Some(tag));
            }
        }
        for code in [0, 1, 100, 205, 1_501, 10_000, 10_099, 11_100, 20_000, u32::MAX] {
            assert_eq!(tag_of(code), None, "{code}");
        }
    }

    // ---------------------------------------------------------------------------------------------- grad_failure

    #[test]
    fn grad_failure_maps_each_namespace_to_its_tag() {
        for tag in TAGS {
            for n in [1, 2, 50, 99] {
                let code = err_code(tag, n);
                let expected = GradFailure { origin: tag, code };
                assert_eq!(grad_failure(Ok(Error::from_contract_error(code))), expected);
                assert_eq!(grad_failure(Err(InvokeError::Contract(code))), expected);
            }
        }
    }

    #[test]
    fn grad_failure_gives_other_contract_codes_origin_0_and_the_raw_code() {
        // Soroswap pair and factory codes, an OpenZeppelin code, and the values next to the namespace.
        for code in [0, 1, 101, 118, 205, 901, 1_501, 10_000, 10_099, 11_100, u32::MAX] {
            let expected = GradFailure { origin: ORIGIN_FOREIGN, code };
            assert_eq!(grad_failure(Ok(Error::from_contract_error(code))), expected);
            assert_eq!(grad_failure(Err(InvokeError::Contract(code))), expected);
        }
    }

    #[test]
    fn grad_failure_gives_host_errors_origin_99_and_their_sc_error_code() {
        let cases = [
            (ScErrorType::Auth, ScErrorCode::InvalidAction),
            (ScErrorType::WasmVm, ScErrorCode::InvalidAction),
            (ScErrorType::Storage, ScErrorCode::MissingValue),
            (ScErrorType::Object, ScErrorCode::ArithDomain),
            (ScErrorType::Value, ScErrorCode::UnexpectedType),
        ];
        for (ty, code) in cases {
            let f = grad_failure(Ok(Error::from_type_and_code(ty, code)));
            assert_eq!(f, GradFailure { origin: ORIGIN_HOST, code: code as u32 });
        }
        assert_eq!(
            grad_failure(Err(InvokeError::Abort)),
            GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InternalError as u32 }
        );
    }

    // ---------------------------------------------------------------------------------------------- through try_

    #[contracterror]
    #[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
    #[repr(u32)]
    pub enum ExecError {
        NotCaller = 10_301,
        PoolNotEmpty = 10_303,
    }
    assert_err_codes!(TAG_EXEC_SOROSWAP; ExecError::NotCaller = 1, ExecError::PoolNotEmpty = 3);

    #[contracterror]
    #[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
    #[repr(u32)]
    pub enum GradError {
        GraduationInvalid = 11_003,
    }
    assert_err_codes!(TAG_MOMENTS_GRADUATOR; GradError::GraduationInvalid = 3);

    #[contracterror]
    #[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
    #[repr(u32)]
    pub enum DexError {
        PairDoesNotExist = 205,
    }

    /// An executor whose behaviour `params.fee_fraction` selects: 0 succeeds, 1 raises its own namespaced error,
    /// 2 a foreign contract's error, 3 a host error (an auth check nobody signed).
    #[contract]
    pub struct TestExecutor;

    #[contractimpl]
    impl TestExecutor {
        pub fn graduate(e: Env, a: GraduateArgs) -> GraduateResult {
            match a.params.fee_fraction {
                1 => panic_with_error!(&e, ExecError::PoolNotEmpty),
                2 => panic_with_error!(&e, DexError::PairDoesNotExist),
                3 => a.source.require_auth(),
                _ => {}
            }
            GraduateResult {
                pool: a.lp_to.clone(),
                lp_token: a.lp_to,
                liquidity: a.min_liquidity,
                token_used: a.token_amount,
                quote_used: a.quote_amount,
            }
        }
    }

    #[contract]
    pub struct TestGraduator;

    #[contractimpl]
    impl TestGraduator {
        pub fn graduate(e: Env, _a: MomentGradArgs) -> MomentGradResult {
            panic_with_error!(&e, GradError::GraduationInvalid)
        }

        pub fn coin_address(_e: Env, nft: Address) -> Address {
            nft
        }
    }

    fn args(e: &Env, mode: u32) -> GraduateArgs {
        GraduateArgs {
            source: Address::generate(e),
            token: Address::generate(e),
            quote: Address::generate(e),
            token_amount: 1_000,
            quote_amount: 2_000,
            lp_to: Address::generate(e),
            params: VenueParams { fee_fraction: mode },
            min_liquidity: 10,
        }
    }

    #[test]
    fn try_graduate_hands_every_error_over_for_grad_failure() {
        let e = Env::default();
        let exec = ExecutorClient::new(&e, &e.register(TestExecutor, ()));

        let ok = args(&e, 0);
        let r = exec.try_graduate(&ok).unwrap().unwrap();
        assert_eq!((r.token_used, r.quote_used, r.liquidity), (1_000, 2_000, 10));

        let failure = |mode| grad_failure(exec.try_graduate(&args(&e, mode)).unwrap_err());
        assert_eq!(failure(1), GradFailure { origin: TAG_EXEC_SOROSWAP, code: 10_303 });
        assert_eq!(failure(2), GradFailure { origin: ORIGIN_FOREIGN, code: 205 });
        assert_eq!(failure(3), GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 });
    }

    #[test]
    fn graduator_errors_keep_their_namespace_through_try() {
        let e = Env::default();
        let grad = GraduatorClient::new(&e, &e.register(TestGraduator, ()));
        let nft = Address::generate(&e);
        let a = MomentGradArgs {
            nft: nft.clone(),
            usdc: Address::generate(&e),
            reserve: 100_000_000,
            pool_coins: 1,
            name: String::from_str(&e, "Moment"),
            symbol: String::from_str(&e, "MOM"),
            expected_coin: Address::generate(&e),
        };
        let f = grad_failure(grad.try_graduate(&a).unwrap_err());
        assert_eq!(f, GradFailure { origin: TAG_MOMENTS_GRADUATOR, code: 11_003 });
        assert_eq!(grad.coin_address(&nft), nft);
    }

    #[test]
    fn graduation_outcome_round_trips() {
        use soroban_sdk::{IntoVal, TryFromVal, Val};
        let e = Env::default();
        let pool = Address::generate(&e);
        for outcome in [
            GraduationOutcome::Graduated(pool),
            GraduationOutcome::Failed(GradFailure { origin: TAG_EXEC_AQUARIUS, code: 10_404 }),
        ] {
            let v: Val = outcome.clone().into_val(&e);
            assert_eq!(GraduationOutcome::try_from_val(&e, &v).unwrap(), outcome);
        }
    }
}
