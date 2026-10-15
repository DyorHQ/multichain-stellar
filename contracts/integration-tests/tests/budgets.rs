//! Resource budgets (§18.3), WASM sizes and dist/, measured on the dist WASMs with `cost_estimate().resources()`.
//!
//! - **Memory of every Soroswap graduation path** on the full WASM stack (launch `graduate` with sharing off and on,
//!   `graduate_fallback` with sharing off and on, Moments `graduate`), each with the longest strings the contracts
//!   accept, measured twice: on a module-cache hit (every module already parsed: what apply charges for live code)
//!   and on a module-cache miss (`clear_module_cache()` right before the call: every VM is parsed and charged, as for
//!   code missing from the cache). A hit must stay within 80% of the network's 41,943,040 B per transaction, a miss
//!   under 100%. Each figure comes from a fresh deployment, because the test host clones its whole storage map per call
//!   frame (about 6.5 KB of modelled memory per ledger entry, an artefact the network doesn't have: there the map holds
//!   only the footprint); a small test ledger keeps the figures close to the network's, and slightly above it.
//! - **Every action of §18.3's table** against its encoded ceiling and the network's per-transaction limits (protocol
//!   29: 400M instructions, 40 MiB memory, 200 write entries, 400 footprint entries, 200,000 read bytes, 132,096
//!   write bytes, 16,384 event bytes), with its rent and fee: the SDK's fee estimate (pubnet fee rates, 2024-12-11
//!   snapshot) on a ledger with testnet's or mainnet's minimum persistent TTL.
//! - **WASM sizes and memory pages** of the dist files, and dist/SHA256SUMS.
//!
//! `cargo test -p dyor-integration-tests --test budgets -- --nocapture` prints every table.
use dyor_integration_tests::*;
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{vec, Address, Bytes, BytesN, Vec};

/// §18.3's ceilings. Where §18.3 left one open, it is the CT-10 measurement (2026-10-15) plus margin.
const TRADE: Ceiling = Ceiling { instructions: 60_000_000, mem_bytes: NET_MEMORY, write_entries: Some(25), read_entries: Some(60) };
const COLLECT_20: Ceiling = Ceiling { instructions: 150_000_000, mem_bytes: NET_MEMORY, write_entries: Some(40), read_entries: None };
const LAUNCH: Ceiling = Ceiling { instructions: 120_000_000, mem_bytes: NET_MEMORY, write_entries: None, read_entries: None };
/// Graduations: the memory ceiling (80% on a cache hit) is checked by the memory tests below.
const GRADUATE: Ceiling = Ceiling { instructions: 250_000_000, mem_bytes: NET_MEMORY, write_entries: Some(80), read_entries: None };
const HARVEST: Ceiling = Ceiling { instructions: 120_000_000, mem_bytes: NET_MEMORY, write_entries: None, read_entries: None };
const CLAIM_FEES_20: Ceiling = Ceiling { instructions: 200_000_000, mem_bytes: NET_MEMORY, write_entries: Some(80), read_entries: None };
/// claim_all × 20 writes 4 entries per Moment plus the signer's nonce: 81 measured (lead note after CT-09, and here).
/// The ceiling is that plus margin, half the network's 200.
const CLAIM_ALL_20: Ceiling = Ceiling { instructions: 200_000_000, mem_bytes: NET_MEMORY, write_entries: Some(100), read_entries: None };
const EXCLUDE_POOL: Ceiling = Ceiling { instructions: 60_000_000, mem_bytes: NET_MEMORY, write_entries: None, read_entries: None };
const OTHER: Ceiling = Ceiling { instructions: 120_000_000, mem_bytes: NET_MEMORY, write_entries: None, read_entries: None };

/// A graduation on a module-cache hit may use at most 80% of the network's memory limit.
const HIT_MEMORY_MAX: i64 = NET_MEMORY * 80 / 100;

fn pct(bytes: i64) -> f64 {
    100.0 * bytes as f64 / NET_MEMORY as f64
}

/// A deployment with the production durations whose invocations are measured, not refused: the ceilings are checked
/// here, so a breach names the action and the figure.
fn world(net: Network) -> World {
    let w = World::new_on(PRODUCTION, net);
    w.e.cost_estimate().disable_resource_limits();
    w
}

fn bytes_of(w: &World, b: &[u8]) -> soroban_sdk::String {
    soroban_sdk::String::from_bytes(&w.e, b)
}

/// The longest launch the launchpad accepts: a 32-byte name, a 10-character symbol, a 256-byte URI, a creator fee and
/// its own recipient, 32 exemptions.
fn max_launch_params(w: &World, venue: u32, sharing: bool) -> launchpad::LaunchParams {
    let mut exempt = Vec::new(&w.e);
    for _ in 0..32 {
        exempt.push_back(Address::generate(&w.e));
    }
    launchpad::LaunchParams {
        name: w.s("A name of exactly thirty-two by!"),
        symbol: w.s("ABCDEFGH12"),
        uri: bytes_of(w, &[b'u'; 256]),
        creator_fee_bps: 1_000,
        creator_fee_recipient: Some(Address::generate(&w.e)),
        snipe_exempt: exempt,
        ..w.params(&w.usdc, venue, sharing)
    }
}

/// The longest Moment moments-v2 accepts (a 32-byte name of four-byte characters, a 10-character symbol, a 256-byte
/// metadata URI, a 64-byte place, a 32-byte date), after governance set the longest external base (256 bytes).
fn max_moment(w: &World) -> Address {
    let mut base = std::string::String::from("https://");
    while base.len() < 256 {
        base.push('a');
    }
    w.m().set_external_base(&w.s(&base));
    let p = moments::PublishParams {
        name: bytes_of(w, &[0xf0, 0x9f, 0x8c, 0x85].repeat(8)),
        symbol: w.s("ABCDEFGH12"),
        metadata_uri: bytes_of(w, &[b'u'; 256]),
        media_hash: BytesN::from_array(&w.e, &[7; 32]),
        place: bytes_of(w, &[b'p'; 64]),
        date: bytes_of(w, &[b'd'; 32]),
        ..w.publish_params()
    };
    w.publish_on(&w.moments, &p)
}

// ------------------------------------------------------------------------------------------------ graduation memory

#[derive(Clone, Copy, Debug)]
enum Path {
    Graduate { sharing: bool },
    Fallback { sharing: bool },
    Moment,
}

impl Path {
    fn label(self) -> std::string::String {
        match self {
            Path::Graduate { sharing } => std::format!("launch graduate on Soroswap (sharing {})", on_off(sharing)),
            Path::Fallback { sharing } => {
                std::format!("launch graduate_fallback on Soroswap (sharing {})", on_off(sharing))
            }
            Path::Moment => "Moments graduate on Soroswap".into(),
        }
    }
}

fn on_off(b: bool) -> &'static str {
    if b {
        "on"
    } else {
        "off"
    }
}

/// One graduation of `path` with the longest strings, on a fresh deployment, measured on a cache hit or a miss.
fn graduation(path: Path, miss: bool) -> Measured {
    let w = world(TESTNET);
    let label = std::format!("{} [{}]", path.label(), if miss { "module-cache miss" } else { "module-cache hit" });
    let cold = |w: &World| {
        if miss {
            w.e.host().clear_module_cache().unwrap();
        }
    };
    match path {
        Path::Graduate { sharing } => {
            let token = w.launch_with(&w.creator, &max_launch_params(&w, SOROSWAP, sharing));
            w.advance(30);
            w.complete(&w.alice, &token);
            let (out, m) = measure(&w.e, &label, || {
                cold(&w);
                w.graduate(&token)
            });
            assert!(matches!(out, launchpad::GraduationOutcome::Graduated(_)), "{out:?}");
            m
        }
        Path::Fallback { sharing } => {
            let token = w.launch_with(&w.creator, &max_launch_params(&w, QA_FAIL, sharing));
            w.advance(30);
            w.complete(&w.alice, &token);
            assert!(matches!(w.graduate(&token), launchpad::GraduationOutcome::Failed(_)));
            w.advance(w.d.launch.fallback_delay);
            let (out, m) = measure(&w.e, &label, || {
                cold(&w);
                w.graduate_fallback(&token)
            });
            assert!(matches!(out, launchpad::GraduationOutcome::Graduated(_)), "{out:?}");
            m
        }
        Path::Moment => {
            let nft = max_moment(&w);
            w.complete_moment_on(&w.moments, &w.alice, &nft);
            let (out, m) = measure(&w.e, &label, || {
                cold(&w);
                w.graduate_moment_on(&w.moments, &nft)
            });
            assert!(matches!(out, moments::GraduationOutcome::Graduated(_)), "{out:?}");
            m
        }
    }
}

/// Measures `path` on a hit and on a miss, prints both, and holds them to the ceilings: memory (hit ≤ 80%, miss
/// < 100% of the network's limit), and on both §18.3's graduation ceilings (250M instructions, 80 write entries) and
/// the network's other limits.
fn graduation_fits(path: Path) {
    let hit = graduation(path, false);
    let miss = graduation(path, true);
    let mut breaches = std::vec::Vec::new();
    for (m, max, what) in [(&hit, HIT_MEMORY_MAX, "80%"), (&miss, NET_MEMORY - 1, "100%")] {
        std::println!(
            "MEMORY | {} | {} B | {:.1}% of {} B | {:.1}M instructions |",
            m.label,
            m.mem_bytes,
            pct(m.mem_bytes),
            NET_MEMORY,
            m.instructions as f64 / 1e6
        );
        if m.mem_bytes > max {
            breaches.push(std::format!("{}: memory {} B ({:.1}%) above {what} of the limit", m.label, m.mem_bytes, pct(m.mem_bytes)));
        }
        breaches.extend(m.breaches(&GRADUATE));
    }
    assert!(breaches.is_empty(), "{}", breaches.join("\n"));
}

#[test]
fn memory_launch_graduate_sharing_off() {
    graduation_fits(Path::Graduate { sharing: false });
}

#[test]
fn memory_launch_graduate_sharing_on() {
    graduation_fits(Path::Graduate { sharing: true });
}

#[test]
fn memory_launch_graduate_fallback_sharing_off() {
    graduation_fits(Path::Fallback { sharing: false });
}

#[test]
fn memory_launch_graduate_fallback_sharing_on() {
    graduation_fits(Path::Fallback { sharing: true });
}

#[test]
fn memory_moments_graduate() {
    graduation_fits(Path::Moment);
}

// ------------------------------------------------------------------------------------------------ every action

struct Table {
    rows: std::vec::Vec<(Measured, Ceiling)>,
}

impl Table {
    fn new() -> Table {
        Table { rows: std::vec::Vec::new() }
    }

    fn record<R>(&mut self, w: &World, label: &str, c: Ceiling, f: impl FnOnce() -> R) -> R {
        let (r, m) = measure(&w.e, label, f);
        self.rows.push((m, c));
        r
    }
}

fn graduated(o: launchpad::GraduationOutcome) -> Address {
    match o {
        launchpad::GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    }
}

/// Launches, trades, the launch fee, refunds.
fn launch_rows(t: &mut Table, net: Network) {
    let w = world(net);
    let pad = w.pad();
    let p = w.params(&w.xlm, SOROSWAP, true);
    let terms = pad.preview_launch_terms(&w.xlm, &SOROSWAP);
    let token = t.record(&w, "launch (XLM, sharing on)", LAUNCH, || pad.launch(&w.creator, &p, &terms));
    let p = launchpad::LaunchParams { initial_buy: 100 * ONE, ..max_launch_params(&w, SOROSWAP, true) };
    let terms = pad.preview_launch_terms(&w.usdc, &SOROSWAP);
    t.record(&w, "launch (USDC, sharing on, 32 exemptions, longest strings, initial buy)", LAUNCH, || {
        pad.launch(&w.creator, &p, &terms)
    });
    w.advance(30);
    t.record(&w, "buy (a holder's first, sharing on)", TRADE, || w.buy(&w.alice, &token, 500 * ONE));
    t.record(&w, "buy (sharing on)", TRADE, || w.buy(&w.alice, &token, 500 * ONE));
    let held = w.balance(&token, &w.alice);
    t.record(&w, "sell (sharing on)", TRADE, || w.sell(&w.alice, &token, held / 4));
    let off = w.launch(&w.xlm, SOROSWAP, false);
    t.record(&w, "buy (a holder's first, sharing off)", TRADE, || w.buy(&w.bob, &off, 500 * ONE));
    let held = w.balance(&off, &w.bob);
    t.record(&w, "sell (sharing off)", TRADE, || w.sell(&w.bob, &off, held / 4));
    t.record(&w, "completing buy (sharing on)", TRADE, || w.buy(&w.carol, &token, 100_000 * ONE));
    assert_eq!(w.curve(&token).phase, launchpad::Phase::Completed);
    t.record(&w, "claim_creator_fees", OTHER, || pad.claim_creator_fees(&off));
}

/// Graduations and fallbacks (their memory is held to its ceiling above), mark_stuck, rescue and refunds.
fn graduation_rows(t: &mut Table, net: Network) {
    for sharing in [true, false] {
        let w = world(net);
        let pad = w.pad();
        let token = w.completed_launch(&w.xlm, SOROSWAP, sharing);
        let label = std::format!("graduate on Soroswap (XLM, sharing {})", on_off(sharing));
        graduated(t.record(&w, &label, GRADUATE, || w.graduate(&token)));
        let token = w.completed_launch(&w.xlm, QA_FAIL, sharing);
        let label = std::format!("graduate, recorded failure (qa-exec-fail mode 0, sharing {})", on_off(sharing));
        let f = t.record(&w, &label, GRADUATE, || w.graduate(&token));
        assert!(matches!(f, launchpad::GraduationOutcome::Failed(_)));
        w.advance(w.d.launch.fallback_delay);
        let label = std::format!("graduate_fallback on Soroswap (XLM, sharing {})", on_off(sharing));
        graduated(t.record(&w, &label, GRADUATE, || w.graduate_fallback(&token)));
        if sharing {
            let token = w.completed_launch(&w.usdc, QA_FAIL, true);
            w.qa().set_mode(&token, &qa_exec_fail::Mode::ExhaustBudget);
            w.advance(w.d.launch.grace);
            t.record(&w, "mark_stuck", OTHER, || w.unsigned(|| pad.mark_stuck(&token)));
            let token = w.completed_launch(&w.usdc, QA_FAIL, true);
            w.graduate(&token);
            w.advance(w.d.launch.rescue_admin);
            t.record(&w, "rescue (admin, sharing on)", OTHER, || pad.rescue(&token));
            let held = w.balance(&token, &w.alice);
            t.record(&w, "refund (sharing on)", TRADE, || pad.refund(&w.alice, &token, &held));
        }
    }
}

/// Harvests, holder claims, exclude_pool and the protocol sweep of a sharing launch; a harvest with sharing off.
fn harvest_rows(t: &mut Table, net: Network) {
    let w = world(net);
    let (token, pool) = w.graduated_launch(&w.usdc, true);
    let (off, pool_off) = w.graduated_launch(&w.usdc, false);
    // A third-party Soroswap pair holding launch tokens while fees accrue, so excluding it strands rewards.
    let other = w.xlm.clone();
    let pair = w.sw_factory().create_pair(&token, &other);
    let stake = w.balance(&token, &w.alice) / 2;
    w.sep41(&token).transfer(&w.alice, &pair, &stake);
    w.sep41(&other).transfer(&w.alice, &pair, &(10 * ONE));
    w.pair(&pair).deposit(&w.alice);
    w.churn(&token, &w.usdc, 5 * ONE, 5);
    w.churn(&off, &w.usdc, 5 * ONE, 5);
    w.advance(w.d.launch.harvest_interval);
    t.record(&w, "harvest (launch, sharing on: exclude_treasury, both sides notified)", HARVEST, || w.harvest(&pool));
    t.record(&w, "harvest (launch, sharing off)", HARVEST, || w.harvest(&pool_off));
    w.advance(10);
    t.record(&w, "claim (holder: quote and launch-token rewards)", TRADE, || w.token(&token).claim(&w.alice));
    t.record(&w, "exclude_pool (Soroswap pair above the floor)", EXCLUDE_POOL, || {
        w.unsigned(|| w.token(&token).exclude_pool(&launch_token::VenueKind::Soroswap, &other, &pair))
    });
    t.record(&w, "sweep_protocol", OTHER, || w.unsigned(|| w.token(&token).sweep_protocol()));
}

/// claim_protocol_fees over the 20 launches it accepts, in two quote assets.
fn claim_fees_rows(t: &mut Table, net: Network) {
    let w = world(net);
    let mut tokens = vec![&w.e];
    for i in 0..20 {
        let q = if i % 2 == 0 { &w.xlm } else { &w.usdc };
        let tk = w.launch(q, SOROSWAP, true);
        w.buy(&w.bob, &tk, 10 * ONE);
        tokens.push_back(tk);
    }
    t.record(&w, "claim_protocol_fees × 20 (two quote assets and the launch fee)", CLAIM_FEES_20, || {
        w.unsigned(|| w.pad().claim_protocol_fees(&tokens))
    });
}

/// Publish, collects, the Moments graduation, vesting claims, a Moment's harvest, expiry and withdrawals.
fn moments_rows(t: &mut Table, net: Network) {
    let w = world(net);
    let m = w.m();
    let p = w.publish_params();
    let terms = m.terms();
    let nft = t.record(&w, "publish", TRADE, || m.publish(&w.creator, &p, &terms));
    t.record(&w, "collect × 1 (a collector's first)", TRADE, || m.collect(&w.bob, &nft, &1, &i128::MAX));
    t.record(&w, "collect × 1", TRADE, || m.collect(&w.bob, &nft, &1, &i128::MAX));
    // A Moment at the price floor, so twenty editions don't complete it.
    let cheap = w.publish_on(&w.moments, &moments::PublishParams { price: ONE / 10, ..w.publish_params() });
    t.record(&w, "collect × 20 (one call, 20 editions)", COLLECT_20, || m.collect(&w.carol, &cheap, &20, &i128::MAX));
    w.complete_moment_on(&w.moments, &w.alice, &nft);
    let g = t.record(&w, "Moments graduate (coin, pool, lock)", GRADUATE, || w.graduate_moment_on(&w.moments, &nft));
    let pool = match g {
        moments::GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    };
    t.record(&w, "claim (vesting, one Moment)", TRADE, || m.claim(&w.alice, &nft));
    t.record(&w, "withdraw_creator", OTHER, || m.withdraw_creator(&nft));
    let coin = m.get_moment(&nft).coin;
    w.churn(&coin, &w.usdc, 2 * ONE, 5);
    w.advance(w.d.moments.harvest_interval);
    t.record(&w, "harvest (Moment: USDC paid 40/60, coins burned)", HARVEST, || w.harvest(&pool));
    // Expiry of a collecting Moment past its deadline.
    let n = w.publish();
    w.collect_on(&w.moments, &w.bob, &n, 1);
    w.advance(DAY + 1);
    t.record(&w, "expire (Collecting)", OTHER, || w.unsigned(|| m.expire(&n)));
}

/// claim_all over 20 graduated Moments.
fn claim_all_rows(t: &mut Table, net: Network) {
    let w = world(net);
    let mut nfts = vec![&w.e];
    for _ in 0..20 {
        let n = w.publish();
        w.complete_moment_on(&w.moments, &w.alice, &n);
        assert!(matches!(w.graduate_moment_on(&w.moments, &n), moments::GraduationOutcome::Graduated(_)));
        nfts.push_back(n);
    }
    w.advance(w.d.moments.vest_period);
    t.record(&w, "claim_all × 20", CLAIM_ALL_20, || w.m().claim_all(&w.alice, &nfts));
    let m = &t.rows.last().unwrap().0;
    assert!(m.write_entries >= 81, "claim_all × 20 wrote {} entries: 4 per Moment plus the nonce expected", m.write_entries);
}

fn report(net: Network) {
    let mut t = Table::new();
    launch_rows(&mut t, net);
    graduation_rows(&mut t, net);
    harvest_rows(&mut t, net);
    claim_fees_rows(&mut t, net);
    moments_rows(&mut t, net);
    claim_all_rows(&mut t, net);
    std::println!(
        "\n### Resources, rent and fee per action ({} ledger: minimum persistent TTL {} ledgers; pubnet fee rates)\n",
        net.name,
        net.min_persistent_ttl
    );
    std::println!("{TABLE_HEADER}");
    let mut breaches = std::vec::Vec::new();
    for (m, c) in &t.rows {
        std::println!("{}", m.row());
        breaches.extend(m.breaches(c));
    }
    assert!(breaches.is_empty(), "budget ceilings exceeded:\n{}", breaches.join("\n"));
}

#[test]
fn every_action_stays_within_its_ceiling_on_testnet() {
    report(TESTNET);
}

#[test]
fn every_action_stays_within_its_ceiling_on_mainnet_rent_settings() {
    report(MAINNET);
}

// ------------------------------------------------------------------------------------------------ sizes and dist

const DIST: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../dist");

fn read(file: &str) -> std::vec::Vec<u8> {
    std::fs::read(std::format!("{DIST}/{file}")).unwrap_or_else(|e| panic!("{file}: {e} (run ./build.sh)"))
}

const V2_WASMS: [&str; 10] = [
    "dyor_launchpad_v2.wasm",
    "dyor_launch_token_v2.wasm",
    "dyor_exec_soroswap.wasm",
    "dyor_exec_aquarius.wasm",
    "dyor_qa_exec_fail.wasm",
    "dyor_lp_locker.wasm",
    "dyor_moments_v2.wasm",
    "dyor_moment_nft.wasm",
    "dyor_moment_coin.wasm",
    "dyor_moments_graduator.wasm",
];

#[test]
fn each_v2_wasm_is_within_its_size_budget() {
    // §18.3: launchpad-v2 and moments-v2 ≤ 110 KB, qa-exec-fail ≤ 16 KB, every other contract ≤ 64 KB; the network
    // allows 131,072 B. Measured on the files build.sh writes: spec-shaken and wasm-opt'd (lead rulings after
    // CT-01..03 and CT-05).
    let kb = 1_024;
    let mut over = std::vec::Vec::new();
    for file in V2_WASMS {
        let budget = match file {
            "dyor_launchpad_v2.wasm" | "dyor_moments_v2.wasm" => 110 * kb,
            "dyor_qa_exec_fail.wasm" => 16 * kb,
            _ => 64 * kb,
        };
        let s = read(file).len();
        std::println!("{file}: {s} B (budget {budget} B)");
        if s > budget || s >= 131_072 {
            over.push(std::format!("{file}: {s} B > {budget} B"));
        }
    }
    assert!(over.is_empty(), "{over:?}");
}

/// Reads an unsigned LEB128 at `i`.
fn leb(b: &[u8], i: &mut usize) -> u64 {
    let (mut r, mut shift) = (0u64, 0);
    loop {
        let x = b[*i];
        *i += 1;
        r |= ((x & 0x7f) as u64) << shift;
        shift += 7;
        if x & 0x80 == 0 {
            return r;
        }
    }
}

/// The initial pages of a WASM's linear memory (its memory section's one entry).
fn initial_pages(wasm: &[u8]) -> u64 {
    assert_eq!(&wasm[..8], b"\0asm\x01\0\0\0", "not a WASM module");
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let size = leb(wasm, &mut i) as usize;
        if id == 5 {
            let mut j = i;
            assert_eq!(leb(wasm, &mut j), 1, "one memory");
            let _flags = leb(wasm, &mut j);
            return leb(wasm, &mut j);
        }
        i += size;
    }
    panic!("no memory section")
}

/// Each VM a graduation instantiates allocates its module's initial linear memory, and a Moments graduation runs
/// about 32 of them, so the v2 crates link a 128 KiB stack instead of Rust's 1 MiB default (build.sh). A v2 WASM
/// declares 3 pages today (2 of stack, then the data section, under 64 KiB), against 17 with the default; the
/// ceiling of 4 leaves room for the data to grow, and a toolchain or build change that drops the flag fails here
/// before the memory tests do.
const MAX_V2_PAGES: u64 = 4;

#[test]
fn each_v2_wasm_declares_a_small_initial_memory() {
    let mut over = std::vec::Vec::new();
    for file in V2_WASMS {
        let pages = initial_pages(&read(file));
        std::println!("{file}: {pages} initial pages ({} B)", pages * 65_536);
        if pages > MAX_V2_PAGES {
            over.push(std::format!("{file}: {pages} pages > {MAX_V2_PAGES}"));
        }
    }
    // v1 is frozen as deployed: Rust's default stack, 17 pages.
    for file in ["dyor_launchpad.wasm", "dyor_launch_token.wasm", "dyor_moments.wasm"] {
        assert_eq!(initial_pages(&read(file)), 17, "{file} must stay byte-identical to the deployed v1");
    }
    assert!(over.is_empty(), "{over:?}");
}

#[test]
fn sha256sums_lists_the_13_wasms_and_v1_matches_the_deployed_hashes() {
    let sums = std::string::String::from_utf8(read("SHA256SUMS")).unwrap();
    let lines: std::vec::Vec<(&str, &str)> = sums
        .lines()
        .map(|l| {
            let (hash, file) = l.split_once("  ").expect("sha256sum format");
            (hash, file.trim_start_matches("dist/"))
        })
        .collect();
    assert_eq!(lines.len(), 13, "{sums}");
    let mut files: std::vec::Vec<&str> = lines.iter().map(|(_, f)| *f).collect();
    files.sort();
    let mut expected: std::vec::Vec<&str> =
        V2_WASMS.iter().copied().chain(["dyor_launchpad.wasm", "dyor_launch_token.wasm", "dyor_moments.wasm"]).collect();
    expected.sort();
    assert_eq!(files, expected);
    // v1 is deployed and frozen: its hashes are the ones the backend pins (testnet.json).
    let deployed = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../backend/supabase/functions/_shared/deployments/testnet.json"
    ))
    .unwrap();
    let pinned = |key: &str| {
        let at = deployed.find(key).unwrap_or_else(|| panic!("{key} in testnet.json"));
        let rest = &deployed[at + key.len()..];
        let start = rest.find('"').unwrap() + 1;
        rest[start..start + 64].to_string()
    };
    for (file, key) in [
        ("dyor_launch_token.wasm", "\"launchTokenWasmHash\""),
        ("dyor_launchpad.wasm", "\"launchpadWasmHash\""),
        ("dyor_moments.wasm", "\"momentsWasmHash\""),
    ] {
        let (hash, _) = lines.iter().find(|(_, f)| *f == file).unwrap_or_else(|| panic!("{file} in SHA256SUMS"));
        assert_eq!(*hash, pinned(key), "{file} no longer reproduces the deployed v1 WASM");
    }
    // Every listed file hashes as listed.
    let e = soroban_sdk::Env::default();
    e.cost_estimate().budget().reset_unlimited();
    for (hash, file) in &lines {
        let digest: BytesN<32> = e.crypto().sha256(&Bytes::from_slice(&e, &read(file))).into();
        let hex: std::string::String = digest.to_array().iter().map(|b| std::format!("{b:02x}")).collect();
        assert_eq!(&hex, hash, "{file}");
    }
}
