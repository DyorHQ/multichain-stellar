//! DyorHQ v2 integration suite (DESIGN-stellar-contracts-v2 §18.2–18.3): journeys, re-entry and squat probes,
//! stateful property tests and resource budgets, run against the real WASMs in dist/ (contractimport!) and the
//! Soroswap fixtures in testdata/. It depends on no contract crate.
//!
//! Owner decision O7 (2026-10-15): launch v2 on Soroswap only. The suite covers the Soroswap venue, the qa-exec-fail
//! venue and the fallback paths; the Aquarius venue, its float and its memory question are out of scope (its code
//! stays, and no test here deploys exec-aquarius).
//!
//! This library is the deployment of §3.4 as a test builds it: every peer at an id fixed before anything is
//! deployed, every contract the WASM `./build.sh` puts in dist/. [`World::new`] takes the production or the
//! testnet-qa durations (§14.3), so each journey runs with both.
//!
//! Nothing here is built for wasm32 or deployed.
#![allow(clippy::too_many_arguments)]
extern crate std;

use core::fmt::Debug;
use dyor_common::{mul_div, LaunchDurations, MomentsDurations, TESTNET_TTL_POLICY};
use soroban_sdk::testutils::{Address as _, EnvTestConfig, Ledger as _};
use soroban_sdk::token::{StellarAssetClient, TokenClient};
use soroban_sdk::xdr::{
    ContractDataDurability, LedgerEntry, LedgerKey, LedgerKeyContractData, ScAddress, ScErrorType, ScVal,
};
use soroban_sdk::{vec, Address, BytesN, Env, IntoVal, InvokeError, String, TryFromVal, Val, Vec};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

// ------------------------------------------------------------------------------------------------ the WASMs

/// The shaken WASMs `./build.sh` writes to dist/: what the owner deploys.
pub mod launchpad {
    soroban_sdk::contractimport!(file = "../dist/dyor_launchpad_v2.wasm");
}
pub mod launch_token {
    soroban_sdk::contractimport!(file = "../dist/dyor_launch_token_v2.wasm");
}
pub mod lp_locker {
    soroban_sdk::contractimport!(file = "../dist/dyor_lp_locker.wasm");
}
pub mod exec_soroswap {
    soroban_sdk::contractimport!(file = "../dist/dyor_exec_soroswap.wasm");
}
pub mod qa_exec_fail {
    soroban_sdk::contractimport!(file = "../dist/dyor_qa_exec_fail.wasm");
}
pub mod moments {
    soroban_sdk::contractimport!(file = "../dist/dyor_moments_v2.wasm");
}
pub mod moment_nft {
    soroban_sdk::contractimport!(file = "../dist/dyor_moment_nft.wasm");
}
pub mod moment_coin {
    soroban_sdk::contractimport!(file = "../dist/dyor_moment_coin.wasm");
}
pub mod graduator {
    soroban_sdk::contractimport!(file = "../dist/dyor_moments_graduator.wasm");
}
/// The Soroswap testnet fixtures (contracts/testdata).
pub mod soroswap_factory {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_factory.wasm");
}
pub mod soroswap_pair {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_pair.wasm");
}
pub mod soroswap_router {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_router.wasm");
}

// ------------------------------------------------------------------------------------------------ constants

/// 7 decimals: one XLM, one USDC, one token, one coin.
pub const ONE: i128 = 10_000_000;
pub const MINUTE: u64 = 60;
pub const HOUR: u64 = 3_600;
pub const DAY: u64 = 86_400;
pub const START: u64 = 1_800_000_000;
pub const START_LEDGER: u32 = 1_000_000;
/// O6: 10 XLM, in stroops.
pub const LAUNCH_FEE: i128 = 100_000_000;
/// §14.1: the XLM phantom 2,000 XLM and the USDC phantom 20 USDC.
pub const XLM_PHANTOM: i128 = 2_000 * ONE;
pub const USDC_PHANTOM: i128 = 20 * ONE;
/// The launch token supply (§14.1) and the Moments coin supply S (§14.2).
pub const SUPPLY: i128 = 1_000_000_000 * ONE;
pub const COIN_SUPPLY: i128 = 100_000_000 * ONE;
/// The venue table of [`World`], in id order (F8: a deployment reads the ids from `venues()`).
pub const SOROSWAP: u32 = 0;
pub const QA_FAIL: u32 = 1;
/// exec-soroswap over a factory that names a pair that already has LP: its `graduate` fails `PoolNotEmpty`.
pub const OCCUPIED: u32 = 2;
/// Moments' testnet threshold (10 USDC) and reserve share (§14.2).
pub const T10: i128 = 10 * ONE;
pub const RESERVE_BPS: u32 = 7_500;
pub const MOMENT_HARVEST_BPS: u32 = 6_667;
pub const BPS: u32 = 10_000;
pub const BASE: &str = "https://dyorhq.fun/moments/";
/// The network's per-transaction limits (protocol 29, §2).
pub const NET_INSTRUCTIONS: i64 = 400_000_000;
pub const NET_MEMORY: i64 = 40 * 1024 * 1024;
pub const NET_WRITE_ENTRIES: u32 = 200;
pub const NET_READ_ENTRIES: u32 = 200;
pub const NET_FOOTPRINT: u32 = 400;
pub const NET_READ_BYTES: u32 = 200_000;
pub const NET_WRITE_BYTES: u32 = 132_096;

/// phantom · (√10 − 1): graduation FDV is 10× launch FDV (§14.1).
pub fn threshold_of(phantom: i128) -> i128 {
    mul_div(phantom, 216_227_766, 100_000_000)
}

/// The two duration sets of §14.3.
#[derive(Clone, Copy, Debug)]
pub struct Durations {
    pub name: &'static str,
    pub launch: LaunchDurations,
    pub moments: MomentsDurations,
}

pub const PRODUCTION: Durations = Durations {
    name: "production",
    launch: dyor_common::PRODUCTION_LAUNCH_DURATIONS,
    moments: dyor_common::PRODUCTION_MOMENTS_DURATIONS,
};
pub const TESTNET_QA: Durations = Durations {
    name: "testnet-qa",
    launch: dyor_common::TESTNET_QA_LAUNCH_DURATIONS,
    moments: dyor_common::TESTNET_QA_MOMENTS_DURATIONS,
};

/// The ledger's rent settings a world runs with: testnet's (the owner deploys there today) or mainnet's (§2).
#[derive(Clone, Copy, Debug)]
pub struct Network {
    pub name: &'static str,
    pub min_persistent_ttl: u32,
    pub min_temp_ttl: u32,
    pub max_ttl: u32,
}
pub const TESTNET: Network =
    Network { name: "testnet", min_persistent_ttl: 120_960, min_temp_ttl: 17_280, max_ttl: 3_110_400 };
pub const MAINNET: Network =
    Network { name: "mainnet", min_persistent_ttl: 2_073_600, min_temp_ttl: 17_280, max_ttl: 3_110_400 };

// ------------------------------------------------------------------------------------------------ conversions

/// Converts between two `#[contracttype]`s of the same shape: dyor-common's and a contractimport!'s.
pub fn cv<A: IntoVal<Env, Val>, B: TryFromVal<Env, Val>>(e: &Env, a: &A) -> B
where
    B::Error: Debug,
{
    let v: Val = a.into_val(e);
    B::try_from_val(e, &v).unwrap()
}

/// The contract error code a `try_` call failed with. Anything else (a value, a host error) panics.
pub fn code<T: Debug, C: Debug, E: Into<soroban_sdk::Error> + Debug>(
    r: Result<Result<T, C>, Result<E, InvokeError>>,
) -> u32 {
    match r {
        Err(Ok(e)) => {
            let e: soroban_sdk::Error = e.into();
            assert!(e.is_type(ScErrorType::Contract), "not a contract error: {e:?}");
            e.get_code()
        }
        Err(Err(InvokeError::Contract(c))) => c,
        other => panic!("expected a contract error, got {other:?}"),
    }
}

/// The value of a `try_` call that must succeed.
pub fn ok<T: Debug, C: Debug, E: Debug>(r: Result<Result<T, C>, Result<E, InvokeError>>) -> T {
    match r {
        Ok(Ok(v)) => v,
        other => panic!("expected a value, got {other:?}"),
    }
}

/// The first line of the abort message of `call`, which must abort (a host error no `try_` can return as a contract
/// error: a missing signature, an exhausted budget).
pub fn abort_of<R>(call: impl FnOnce() -> R) -> std::string::String {
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(_) => panic!("the call succeeded"),
        Err(p) => p
            .downcast_ref::<std::string::String>()
            .cloned()
            .or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default(),
    }
}

// ------------------------------------------------------------------------------------------------ the world

/// The deployment of §3.4 in one test host. Ids are fixed first, then each contract is deployed at its id:
/// executors, the locker, the graduators, then launchpad-v2 and moments-v2 (and testnet-qa's failing Moments stack:
/// a second moments-v2 and graduator over qa-exec-fail, §3.1).
pub struct World {
    pub e: Env,
    pub d: Durations,
    pub net: Network,
    pub admin: Address,
    pub guardian: Address,
    pub treasury: Address,
    pub qa_admin: Address,
    pub governance: Address,
    pub platform: Address,
    pub m_treasury: Address,
    pub creator: Address,
    pub alice: Address,
    pub bob: Address,
    pub carol: Address,
    pub trader: Address,
    pub attacker: Address,
    pub xlm: Address,
    pub usdc: Address,
    /// testnet-qa's classic test asset, quoted only on the qa-exec-fail venue with the Soroswap fallback: a
    /// venue-locked quote (§14.1).
    pub qa_asset: Address,
    pub factory: Address,
    pub router: Address,
    pub locker: Address,
    pub exec: Address,
    pub qa: Address,
    pub occupied: Address,
    pub pad: Address,
    pub moments: Address,
    pub graduator: Address,
    pub fail_moments: Address,
    pub fail_graduator: Address,
    pub token_hash: BytesN<32>,
    pub nft_hash: BytesN<32>,
    pub coin_hash: BytesN<32>,
    pub aquarius_router: Address,
    nonce: Cell<u64>,
}

pub fn new_env(net: Network) -> Env {
    let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    e.ledger().with_mut(|l| {
        l.timestamp = START;
        l.sequence_number = START_LEDGER;
        l.min_persistent_entry_ttl = net.min_persistent_ttl;
        l.min_temp_entry_ttl = net.min_temp_ttl;
        l.max_entry_ttl = net.max_ttl;
    });
    e
}

impl World {
    pub fn new(d: Durations) -> World {
        World::new_on(d, TESTNET)
    }

    pub fn new_on(d: Durations, net: Network) -> World {
        World::build(new_env(net), d, net, &[])
    }

    /// A world whose venue table has `extra` venues after the three standard ones (ids 3, 4, …).
    pub fn with_venues(d: Durations, extra: &[(launchpad::VenueKind, Address)]) -> World {
        let e = new_env(TESTNET);
        World::build(e, d, TESTNET, extra)
    }

    pub fn build(e: Env, d: Durations, net: Network, extra: &[(launchpad::VenueKind, Address)]) -> World {
        let g = || Address::generate(&e);
        let (admin, guardian, treasury, qa_admin, governance, platform, m_treasury) = (g(), g(), g(), g(), g(), g(), g());
        let (creator, alice, bob, carol, trader, attacker) = (g(), g(), g(), g(), g(), g());
        let sac = |e: &Env| e.register_stellar_asset_contract_v2(Address::generate(e)).address();
        let (xlm, usdc, qa_asset) = (sac(&e), sac(&e), sac(&e));
        for who in [&creator, &alice, &bob, &carol, &trader, &attacker] {
            StellarAssetClient::new(&e, &xlm).mint(who, &(1_000_000 * ONE));
            StellarAssetClient::new(&e, &usdc).mint(who, &(1_000_000 * ONE));
            StellarAssetClient::new(&e, &qa_asset).mint(who, &(1_000_000 * ONE));
        }

        let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
        let factory = e.register(soroswap_factory::WASM, ());
        soroswap_factory::Client::new(&e, &factory).initialize(&admin, &pair_hash);
        let router = e.register(soroswap_router::WASM, ());
        soroswap_router::Client::new(&e, &router).initialize(&factory);

        // Fixed ids first (§3.4).
        let (pad, moments_id, graduator_id, fail_moments, fail_graduator) = (g(), g(), g(), g(), g());
        let interval = d.launch.harvest_interval;
        assert_eq!(interval, d.moments.harvest_interval);
        let locker = e.register(
            lp_locker::WASM,
            (vec![&e, pad.clone(), moments_id.clone()], factory.clone(), None::<Address>, interval),
        );
        let exec = e.register(exec_soroswap::WASM, (factory.clone(), vec![&e, pad.clone(), graduator_id.clone()]));
        let qa = e.register(
            qa_exec_fail::WASM,
            (vec![&e, pad.clone(), fail_graduator.clone()], qa_admin.clone(), qa_exec_fail::Mode::Fail),
        );
        let occupied = occupied_executor(&e, &admin, &factory, &vec![&e, pad.clone()]);
        let token_hash = e.deployer().upload_contract_wasm(launch_token::WASM);
        let nft_hash = e.deployer().upload_contract_wasm(moment_nft::WASM);
        let coin_hash = e.deployer().upload_contract_wasm(moment_coin::WASM);
        e.register_at(
            &graduator_id,
            graduator::WASM,
            (moments_id.clone(), coin_hash.clone(), exec.clone(), locker.clone(), factory.clone()),
        );
        e.register_at(
            &fail_graduator,
            graduator::WASM,
            (fail_moments.clone(), coin_hash.clone(), qa.clone(), locker.clone(), factory.clone()),
        );

        let aquarius_router = g();
        let mut venues = vec![
            &e,
            venue(launchpad::VenueKind::Soroswap, &exec),
            venue(launchpad::VenueKind::QaFail, &qa),
            venue(launchpad::VenueKind::Soroswap, &occupied),
        ];
        for (kind, executor) in extra {
            venues.push_back(venue(*kind, executor));
        }
        e.register_at(
            &pad,
            launchpad::WASM,
            (
                admin.clone(),
                Some(guardian.clone()),
                treasury.clone(),
                xlm.clone(),
                token_hash.clone(),
                locker.clone(),
                factory.clone(),
                aquarius_router.clone(),
                LAUNCH_FEE,
                venues,
                d.launch,
                TESTNET_TTL_POLICY,
            ),
        );
        let w = World {
            e,
            d,
            net,
            admin,
            guardian,
            treasury,
            qa_admin,
            governance,
            platform,
            m_treasury,
            creator,
            alice,
            bob,
            carol,
            trader,
            attacker,
            xlm,
            usdc,
            qa_asset,
            factory,
            router,
            locker,
            exec,
            qa,
            occupied,
            pad,
            moments: moments_id,
            graduator: graduator_id,
            fail_moments,
            fail_graduator,
            token_hash,
            nft_hash,
            coin_hash,
            aquarius_router,
            nonce: Cell::new(0),
        };
        w.deploy_moments(&w.moments, &w.graduator, &w.exec);
        w.deploy_moments(&w.fail_moments, &w.fail_graduator, &w.qa);
        let p = w.pad();
        let none = Vec::<u32>::new(&w.e);
        p.set_quote(&w.xlm, &XLM_PHANTOM, &threshold_of(XLM_PHANTOM), &true, &none, &SOROSWAP);
        p.set_quote(&w.usdc, &USDC_PHANTOM, &threshold_of(USDC_PHANTOM), &true, &none, &SOROSWAP);
        p.set_quote(&w.qa_asset, &XLM_PHANTOM, &threshold_of(XLM_PHANTOM), &true, &vec![&w.e, QA_FAIL], &SOROSWAP);
        w
    }

    /// moments-v2 at `id` over `graduator` (already deployed with `executor`), with the testnet policy (§14.2).
    pub fn deploy_moments(&self, id: &Address, graduator: &Address, executor: &Address) {
        self.e.register_at(
            id,
            moments::WASM,
            (
                self.governance.clone(),
                Some(self.guardian.clone()),
                self.usdc.clone(),
                self.nft_hash.clone(),
                graduator.clone(),
                self.locker.clone(),
                executor.clone(),
                self.factory.clone(),
                String::from_str(&self.e, BASE),
                self.policy(),
                self.d.moments,
                TESTNET_TTL_POLICY,
            ),
        );
    }

    /// A further Moments stack (moments-v2 and its graduator) over `executor`, at fresh ids.
    pub fn moments_stack(&self, executor: &Address) -> (Address, Address) {
        let (m, g) = (Address::generate(&self.e), Address::generate(&self.e));
        self.e.register_at(
            &g,
            graduator::WASM,
            (m.clone(), self.coin_hash.clone(), executor.clone(), self.locker.clone(), self.factory.clone()),
        );
        self.deploy_moments(&m, &g, executor);
        (m, g)
    }

    /// The testnet policy of §14.2: T = 10 USDC, 0.10 USDC minimum, 20/5/75, 10% maximum allocation, 70% to the
    /// creator at expiry, a 5% royalty.
    pub fn policy(&self) -> moments::Policy {
        moments::Policy {
            threshold: T10,
            min_price: ONE / 10,
            creator_bps: 2_000,
            platform_bps: 500,
            reserve_bps: RESERVE_BPS,
            max_creator_alloc_bps: 1_000,
            expiry_creator_bps: 7_000,
            royalty_bps: 500,
            platform: self.platform.clone(),
            treasury: self.m_treasury.clone(),
        }
    }

    // -------------------------------------------------------------------------------------------- clients

    pub fn pad(&self) -> launchpad::Client<'_> {
        launchpad::Client::new(&self.e, &self.pad)
    }
    pub fn token(&self, token: &Address) -> launch_token::Client<'_> {
        launch_token::Client::new(&self.e, token)
    }
    pub fn sep41(&self, token: &Address) -> TokenClient<'_> {
        TokenClient::new(&self.e, token)
    }
    pub fn locker(&self) -> lp_locker::Client<'_> {
        lp_locker::Client::new(&self.e, &self.locker)
    }
    pub fn qa(&self) -> qa_exec_fail::Client<'_> {
        qa_exec_fail::Client::new(&self.e, &self.qa)
    }
    pub fn m(&self) -> moments::Client<'_> {
        moments::Client::new(&self.e, &self.moments)
    }
    pub fn m_at(&self, id: &Address) -> moments::Client<'_> {
        moments::Client::new(&self.e, id)
    }
    pub fn nft(&self, nft: &Address) -> moment_nft::Client<'_> {
        moment_nft::Client::new(&self.e, nft)
    }
    pub fn coin(&self, coin: &Address) -> moment_coin::Client<'_> {
        moment_coin::Client::new(&self.e, coin)
    }
    pub fn pair(&self, pair: &Address) -> soroswap_pair::Client<'_> {
        soroswap_pair::Client::new(&self.e, pair)
    }
    pub fn sw_factory(&self) -> soroswap_factory::Client<'_> {
        soroswap_factory::Client::new(&self.e, &self.factory)
    }
    pub fn balance(&self, asset: &Address, who: &Address) -> i128 {
        self.sep41(asset).balance(who)
    }
    /// `total_supply()` of a launch token or a Moment coin (SEP-41 has no such function; both contracts do).
    pub fn supply(&self, token: &Address) -> i128 {
        self.e.invoke_contract(token, &soroban_sdk::Symbol::new(&self.e, "total_supply"), Vec::new(&self.e))
    }
    pub fn mint(&self, asset: &Address, to: &Address, amount: i128) {
        StellarAssetClient::new(&self.e, asset).mint(to, &amount);
    }
    pub fn s(&self, s: &str) -> String {
        String::from_str(&self.e, s)
    }

    // -------------------------------------------------------------------------------------------- time

    pub fn now(&self) -> u64 {
        self.e.ledger().timestamp()
    }
    pub fn seq(&self) -> u32 {
        self.e.ledger().sequence()
    }
    /// Moves time forward by `secs` and the ledger sequence by at least one ledger (5 s ledgers), with the keeper of
    /// §13 running meanwhile: every persistent entry (instances, code, per-launch and per-Moment records, balances) is
    /// kept alive across the jump, so a journey that waits 7 or 150 days doesn't meet archived entries. (On the network
    /// the keeper extends instances, code and records, and the user's own archived entries restore automatically in
    /// the user's transaction; neither changes what a call does.) Temporary entries lapse as they would.
    pub fn advance(&self, secs: u64) {
        let to = self.seq() + core::cmp::max(1, (secs / 5) as u32);
        keep_alive(&self.e, to);
        self.e.ledger().with_mut(|l| {
            l.timestamp += secs;
            l.sequence_number = to;
        });
    }
    pub fn set_time(&self, at: u64) {
        assert!(at >= self.now(), "time only moves forward");
        self.advance(at - self.now());
    }

    /// Runs `f` with auth enforced and nobody's signature, as a keeper or anyone sends a permissionless call.
    pub fn unsigned<R>(&self, f: impl FnOnce() -> R) -> R {
        self.e.set_auths(&[]);
        let r = f();
        self.e.mock_all_auths();
        r
    }

    // -------------------------------------------------------------------------------------------- launches

    pub fn next_nonce(&self) -> u64 {
        self.nonce.set(self.nonce.get() + 1);
        self.nonce.get()
    }

    pub fn params(&self, quote: &Address, venue: u32, sharing: bool) -> launchpad::LaunchParams {
        launchpad::LaunchParams {
            quote: quote.clone(),
            name: self.s("Dyor Cat"),
            symbol: self.s("DCAT"),
            uri: self.s("https://lite.dyorhq.fun/m/dcat.json"),
            creator_fee_bps: 0,
            venue,
            holder_sharing: sharing,
            creator_fee_recipient: None,
            snipe_exempt: Vec::new(&self.e),
            initial_buy: 0,
            min_tokens_out: 0,
            nonce: self.next_nonce(),
        }
    }

    pub fn launch_with(&self, creator: &Address, p: &launchpad::LaunchParams) -> Address {
        let terms = self.pad().preview_launch_terms(&p.quote, &p.venue);
        self.pad().launch(creator, p, &terms)
    }

    /// A launch by the creator, then 30 s so that no later buy pays the snipe tax (§14.1: four 5-second steps).
    pub fn launch(&self, quote: &Address, venue: u32, sharing: bool) -> Address {
        let token = self.launch_with(&self.creator, &self.params(quote, venue, sharing));
        self.advance(30);
        token
    }

    pub fn buy(&self, who: &Address, token: &Address, quote_in: i128) -> i128 {
        self.pad().buy(who, token, &quote_in, &0)
    }

    pub fn sell(&self, who: &Address, token: &Address, tokens_in: i128) -> i128 {
        self.pad().sell(who, token, &tokens_in, &0)
    }

    pub fn curve(&self, token: &Address) -> launchpad::Curve {
        self.pad().get_curve(token)
    }

    /// `who` buys the rest of the curve: the clamp takes exactly what completes it (§5.5).
    pub fn complete(&self, who: &Address, token: &Address) -> i128 {
        let c = self.curve(token);
        // Enough for the remaining gap under any fee mix, snipe tax included (fees never take more than 99%).
        let out = self.buy(who, token, (c.threshold - c.real_quote) * 100 + ONE);
        assert_eq!(self.curve(token).phase, launchpad::Phase::Completed);
        out
    }

    /// `graduate` as the keeper sends it: auth enforced, nobody's signature.
    pub fn graduate(&self, token: &Address) -> launchpad::GraduationOutcome {
        self.unsigned(|| self.pad().graduate(token))
    }
    pub fn try_graduate(&self, token: &Address) -> Result<launchpad::GraduationOutcome, u32> {
        self.unsigned(|| match self.pad().try_graduate(token) {
            Ok(Ok(v)) => Ok(v),
            r => Err(code(r)),
        })
    }
    pub fn graduate_fallback(&self, token: &Address) -> launchpad::GraduationOutcome {
        self.unsigned(|| self.pad().graduate_fallback(token))
    }
    pub fn try_graduate_fallback(&self, token: &Address) -> Result<launchpad::GraduationOutcome, u32> {
        self.unsigned(|| match self.pad().try_graduate_fallback(token) {
            Ok(Ok(v)) => Ok(v),
            r => Err(code(r)),
        })
    }

    /// The pool of a graduated launch.
    pub fn pool_of(&self, token: &Address) -> Address {
        self.curve(token).pool.expect("graduated")
    }

    /// A launch on `venue` with `quote`, bought by Alice and Bob, completed by Carol.
    pub fn completed_launch(&self, quote: &Address, venue: u32, sharing: bool) -> Address {
        let token = self.launch(quote, venue, sharing);
        let c = self.curve(&token);
        let step = (c.threshold - c.real_quote) / 4;
        self.buy(&self.alice, &token, step);
        self.buy(&self.bob, &token, step);
        self.complete(&self.carol, &token);
        token
    }

    /// A launch graduated on Soroswap.
    pub fn graduated_launch(&self, quote: &Address, sharing: bool) -> (Address, Address) {
        let token = self.completed_launch(quote, SOROSWAP, sharing);
        match self.graduate(&token) {
            launchpad::GraduationOutcome::Graduated(pool) => (token, pool),
            f => panic!("graduation failed: {f:?}"),
        }
    }

    /// Swaps `amount_in` of `token_in` for `token_out` on the Soroswap router as `who`. Returns what came out.
    pub fn swap(&self, who: &Address, token_in: &Address, token_out: &Address, amount_in: i128) -> i128 {
        let path = vec![&self.e, token_in.clone(), token_out.clone()];
        let router = soroswap_router::Client::new(&self.e, &self.router);
        let out = router.swap_exact_tokens_for_tokens(&amount_in, &0, &path, who, &(self.now() + 600));
        out.get_unchecked(1)
    }

    /// [`World::swap`], or `None` when the router refuses it (an output of zero, say).
    pub fn try_swap(&self, who: &Address, token_in: &Address, token_out: &Address, amount_in: i128) -> Option<i128> {
        let path = vec![&self.e, token_in.clone(), token_out.clone()];
        let router = soroswap_router::Client::new(&self.e, &self.router);
        match router.try_swap_exact_tokens_for_tokens(&amount_in, &0, &path, who, &(self.now() + 600)) {
            Ok(Ok(out)) => Some(out.get_unchecked(1)),
            _ => None,
        }
    }

    /// The pair's reserves as (reserve of `a`, reserve of `b`).
    pub fn reserves(&self, pair: &Address, a: &Address) -> (i128, i128) {
        let p = self.pair(pair);
        let (r0, r1) = p.get_reserves();
        if &p.token_0() == a {
            (r0, r1)
        } else {
            (r1, r0)
        }
    }

    /// `locker.harvest(pool)` as the keeper sends it.
    pub fn harvest(&self, pool: &Address) -> (i128, i128) {
        self.unsigned(|| self.locker().harvest(pool))
    }

    pub fn try_harvest(&self, pool: &Address) -> Result<(i128, i128), u32> {
        self.unsigned(|| match self.locker().try_harvest(pool) {
            Ok(Ok(v)) => Ok(v),
            r => Err(code(r)),
        })
    }

    /// Round trips on the router (buy then sell back), leaving fee growth in the pool.
    pub fn churn(&self, token: &Address, quote: &Address, quote_in: i128, rounds: u32) {
        for _ in 0..rounds {
            let got = self.swap(&self.trader, quote, token, quote_in);
            self.swap(&self.trader, token, quote, got);
        }
    }

    // -------------------------------------------------------------------------------------------- Moments

    /// A Moment at 1 USDC, 10% allocation, a one-day window and the next nonce.
    pub fn publish_params(&self) -> moments::PublishParams {
        moments::PublishParams {
            name: self.s("Sunset at Labadi"),
            symbol: self.s("LABADI"),
            metadata_uri: self.s("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/moment.json"),
            media_hash: BytesN::from_array(&self.e, &[7; 32]),
            place: self.s("Accra, Ghana"),
            date: self.s("2026-10-14"),
            price: ONE,
            creator_alloc_bps: 1_000,
            window_secs: DAY,
            nonce: self.next_nonce(),
        }
    }

    pub fn publish_on(&self, m: &Address, p: &moments::PublishParams) -> Address {
        let c = self.m_at(m);
        c.publish(&self.creator, p, &c.terms())
    }

    pub fn publish(&self) -> Address {
        self.publish_on(&self.moments, &self.publish_params())
    }

    pub fn collect_on(&self, m: &Address, who: &Address, nft: &Address, qty: u32) -> moments::CollectResult {
        self.m_at(m).collect(who, nft, &qty, &i128::MAX)
    }

    /// `who` collects until the Moment completes (it must be 20 editions or fewer away).
    pub fn complete_moment_on(&self, m: &Address, who: &Address, nft: &Address) -> moments::CollectResult {
        let c = self.m_at(m);
        let mo = c.get_moment(nft);
        let l = c.ledger(nft);
        let gross = dyor_common::mul_div_up(mo.threshold - l.reserve, BPS as i128, mo.reserve_bps as i128);
        let qty = dyor_common::mul_div_up(gross, 1, mo.price) as u32;
        let r = self.collect_on(m, who, nft, qty);
        assert_eq!(c.ledger(nft).state, moments::State::GraduationPending);
        r
    }

    pub fn graduate_moment_on(&self, m: &Address, nft: &Address) -> moments::GraduationOutcome {
        self.unsigned(|| self.m_at(m).graduate(nft))
    }

    /// A Moment published on the main stack, completed by Alice and graduated.
    pub fn graduated_moment(&self) -> (Address, Address) {
        let nft = self.publish();
        self.collect_on(&self.moments, &self.bob, &nft, 3);
        self.complete_moment_on(&self.moments, &self.alice, &nft);
        match self.graduate_moment_on(&self.moments, &nft) {
            moments::GraduationOutcome::Graduated(pool) => (nft, pool),
            f => panic!("Moment graduation failed: {f:?}"),
        }
    }
}

fn venue(kind: launchpad::VenueKind, executor: &Address) -> launchpad::VenueInit {
    launchpad::VenueInit { kind, executor: executor.clone(), params: launchpad::VenueParams { fee_fraction: 0 } }
}

/// A factory that names one pair, which already has LP, for every token pair: exec-soroswap over it fails
/// `PoolNotEmpty` (the tripwire of §7, which the lock makes unreachable on the real factory).
#[soroban_sdk::contract]
pub struct StubFactory;

#[soroban_sdk::contractimpl]
impl StubFactory {
    pub fn __constructor(e: Env, pair: Address) {
        e.storage().instance().set(&soroban_sdk::symbol_short!("pair"), &pair);
    }
    pub fn pair_exists(_e: Env, _token_a: Address, _token_b: Address) -> bool {
        true
    }
    pub fn get_pair(e: Env, _token_a: Address, _token_b: Address) -> Address {
        e.storage().instance().get(&soroban_sdk::symbol_short!("pair")).unwrap()
    }
}

/// exec-soroswap (the real WASM) over a factory that always names a pair of two other assets that already has LP.
pub fn occupied_executor(e: &Env, admin: &Address, factory: &Address, callers: &Vec<Address>) -> Address {
    let (a, b) = (
        e.register_stellar_asset_contract_v2(admin.clone()).address(),
        e.register_stellar_asset_contract_v2(admin.clone()).address(),
    );
    let pair = soroswap_factory::Client::new(e, factory).create_pair(&a, &b);
    StellarAssetClient::new(e, &a).mint(&pair, &(1_000 * ONE));
    StellarAssetClient::new(e, &b).mint(&pair, &(1_000 * ONE));
    soroswap_pair::Client::new(e, &pair).deposit(admin);
    let stub = e.register(StubFactory, (pair,));
    e.register(exec_soroswap::WASM, (stub, callers.clone()))
}

// ------------------------------------------------------------------------------------------------ storage probes

/// Every live entry the host holds, by key.
pub fn stored(e: &Env) -> BTreeMap<LedgerKey, (Rc<LedgerEntry>, Option<u32>)> {
    let entries = e.host().get_stored_entries().unwrap();
    entries.into_iter().filter_map(|(k, v)| v.map(|v| ((*k).clone(), v))).collect()
}

/// The keeper's TTL sweep (§13) before the ledger moves to `to`: every persistent entry that would be archived by
/// then lives until `to` plus the network's minimum persistent TTL.
pub fn keep_alive(e: &Env, to: u32) {
    let min = e.ledger().get().min_persistent_entry_ttl;
    for (k, v) in e.host().get_stored_entries().unwrap() {
        let Some((entry, Some(live_until))) = v else { continue };
        let persistent = match &*k {
            LedgerKey::ContractCode(_) => true,
            LedgerKey::ContractData(d) => d.durability == ContractDataDurability::Persistent,
            _ => false,
        };
        if persistent && live_until < to {
            e.host().add_ledger_entry(&k, &entry, Some(to + min)).unwrap();
        }
    }
}

/// Runs `f` and returns the keys it wrote: new entries, replaced entries (the host stores every write as a new `Rc`)
/// and entries whose TTL changed.
pub fn writes<R>(e: &Env, f: impl FnOnce() -> R) -> (R, std::vec::Vec<LedgerKey>) {
    let before = stored(e);
    let r = f();
    let written = stored(e)
        .into_iter()
        .filter(|(k, (entry, ttl))| match before.get(k) {
            None => true,
            Some((old, old_ttl)) => !Rc::ptr_eq(old, entry) || old_ttl != ttl,
        })
        .map(|(k, _)| k)
        .collect();
    (r, written)
}

/// The contract a contract-data key belongs to, if it is one.
pub fn key_contract(k: &LedgerKey) -> Option<ScAddress> {
    match k {
        LedgerKey::ContractData(LedgerKeyContractData { contract, .. }) => Some(contract.clone()),
        _ => None,
    }
}

pub fn is_instance(k: &LedgerKey) -> bool {
    matches!(k, LedgerKey::ContractData(LedgerKeyContractData { key: ScVal::LedgerKeyContractInstance, .. }))
}

pub fn is_nonce(k: &LedgerKey) -> bool {
    matches!(k, LedgerKey::ContractData(LedgerKeyContractData { key: ScVal::LedgerKeyNonce(_), .. }))
}

pub fn sc(a: &Address) -> ScAddress {
    a.into()
}

/// The ledger key of `contract`'s instance.
pub fn instance_key(contract: &Address) -> LedgerKey {
    LedgerKey::ContractData(LedgerKeyContractData {
        contract: contract.into(),
        key: ScVal::LedgerKeyContractInstance,
        durability: ContractDataDurability::Persistent,
    })
}

/// The persistent `contract`-data key whose key value is `key`.
pub fn data_key<K: IntoVal<Env, Val>>(e: &Env, contract: &Address, key: K, durability: ContractDataDurability) -> LedgerKey {
    let v: Val = key.into_val(e);
    LedgerKey::ContractData(LedgerKeyContractData {
        contract: contract.into(),
        key: ScVal::try_from_val(e, &v).unwrap(),
        durability,
    })
}

// ------------------------------------------------------------------------------------------------ budgets

/// One measured action: the resources of the last top-level invocation (`cost_estimate().resources()`) and its fee
/// estimate at the network's fee snapshot the SDK carries.
#[derive(Clone, Debug)]
pub struct Measured {
    pub label: std::string::String,
    pub instructions: i64,
    pub mem_bytes: i64,
    pub read_entries: u32,
    pub write_entries: u32,
    pub read_bytes: u32,
    pub write_bytes: u32,
    pub events_bytes: u32,
    pub rent_stroops: i64,
    pub fee_stroops: i64,
}

/// The resources of the invocation `f` makes last.
pub fn measure<R>(e: &Env, label: &str, f: impl FnOnce() -> R) -> (R, Measured) {
    let r = f();
    let res = e.cost_estimate().resources();
    let fee = e.cost_estimate().fee();
    let m = Measured {
        label: label.to_string(),
        instructions: res.instructions,
        mem_bytes: res.mem_bytes,
        read_entries: res.disk_read_entries + res.memory_read_entries,
        write_entries: res.write_entries,
        read_bytes: res.disk_read_bytes,
        write_bytes: res.write_bytes,
        events_bytes: res.contract_events_size_bytes,
        rent_stroops: fee.persistent_entry_rent + fee.temporary_entry_rent,
        fee_stroops: fee.total,
    };
    (r, m)
}

/// Ceilings for one action. `None` leaves a resource to the network limit alone.
#[derive(Clone, Copy, Debug)]
pub struct Ceiling {
    pub instructions: i64,
    pub mem_bytes: i64,
    pub write_entries: Option<u32>,
    pub read_entries: Option<u32>,
}

impl Measured {
    /// The ceilings this measurement breaks, if any. The network's own limits always apply.
    pub fn breaches(&self, c: &Ceiling) -> std::vec::Vec<std::string::String> {
        let mut out = std::vec::Vec::new();
        let mut check = |what: &str, v: i64, max: i64| {
            if v > max {
                out.push(std::format!("{}: {} {} > {}", self.label, what, v, max));
            }
        };
        check("instructions", self.instructions, c.instructions.min(NET_INSTRUCTIONS));
        check("memory bytes", self.mem_bytes, c.mem_bytes.min(NET_MEMORY));
        check("write entries", self.write_entries as i64, c.write_entries.unwrap_or(NET_WRITE_ENTRIES) as i64);
        check("footprint entries", self.read_entries as i64, c.read_entries.unwrap_or(NET_FOOTPRINT) as i64);
        check("write bytes", self.write_bytes as i64, NET_WRITE_BYTES as i64);
        check("read bytes", self.read_bytes as i64, NET_READ_BYTES as i64);
        check("event bytes", self.events_bytes as i64, 16_384);
        out
    }

    pub fn row(&self) -> std::string::String {
        std::format!(
            "| {} | {:.1}M | {:.1} MB | {} | {} | {} | {} | {:.7} | {:.7} |",
            self.label,
            self.instructions as f64 / 1e6,
            self.mem_bytes as f64 / 1e6,
            self.read_entries,
            self.write_entries,
            self.read_bytes,
            self.write_bytes,
            self.rent_stroops as f64 / 1e7,
            self.fee_stroops as f64 / 1e7,
        )
    }
}

pub const TABLE_HEADER: &str = "| action | instructions | memory | footprint entries (read+write) | write entries | disk read bytes | write bytes | rent (XLM) | total fee (XLM) |\n|---|---|---|---|---|---|---|---|---|";
