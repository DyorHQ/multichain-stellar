#!/usr/bin/env python3
"""Every place the app learns the launchpad's and Moments' live addresses must agree with contracts/deployments/.

Checks the DyorKit constants (LaunchpadAddresses.monadMainnet against 143.json, MomentsAddresses.monadMainnet against
moments-143.json) and — when they set the keys — the gitignored local configs (ios Secrets.xcconfig, and the .env /
.env.local that scripts read). Also fails when a live record's factory is a retired one, or when a local config holds a
retired payout wallet. Exit 1 on any problem. Run after a redeploy and before a release.

The v2 addresses are unknown until the owner deploys, so each DyorKit block may be PENDING: every module `.zero` under a
`// PENDING` marker. A pending block is fine only while its live record is not promoted yet (143.json still names the
relaunch factory 0x6B1C…, moments-143.json still cohort 3, 0x0FD4…), so the Swift wiring and the record promotion land
together. `--release` is the archive gate (the DyorHQ target's install-only build phase in ios/project.yml,
ios/ci_scripts/ci_post_xcodebuild.sh, ios/scripts/testflight.sh): it refuses while either block is pending.

The retired Moments cohorts (MomentLink.Cohort c1–c3) are final only by their pins: `finalMomentCount` names how many
Moments each has, and MomentsAddresses.retiredMainnetCoins every coin they minted. Every run checks the two tables agree
(each cohort's coins are ids 1…pin). `--chain` and `--release` also prove them on Monad with read-only eth_calls to a
keyless public RPC (never a transaction): each factory's momentCount() equals the pin, and its Moments' coins are
exactly its retiredMainnetCoins entries; a cohort that grew past its pin refuses, naming the new coins, and so does an
unreachable RPC. Cohort 3 alone need not be paused on chain: it stays open (owner decision 2026-09-28: the old stacks
are retired in the app only, and builds before 16 can still publish there), so its publishingPaused() is read and
reported as a note, and its count is proven again by every release. Cohorts 1 and 2 must stay paused (their policy
pays the retired wallets): an open one refuses. `--chain` runs the same checks by hand; `--release` includes them.
Names do not follow the pins: MomentLink.Cohort.namedMomentCount freezes how many of each retired cohort's Moments have a
name link (NAMED_MOMENTS here, never changed), so raising a pin for a Moment published later takes in its coin and
moves no link. Every run checks the Swift still says NAMED_MOMENTS, and no more than the pin.

The same reads prove the live stacks, once wired, so a wrong record promoted with Swift that matches it (the simulated
dryrun-143.json, a fork rehearsal's, another deployment's) still refuses: every module in DyorKit's two tables has code;
the launchpad factory's hook(), escrow(), holderFeeSharing() and router() are the table's, its owner() is 143.json's and
modulesSealed() is true; the Moments factory's collect(), vesting(), graduation(), locker(), feeHook() and buyback() are
the table's, externalBaseURI() is the c4 link base, policy() pays the table's platform and treasury, and governance()
and guardian() are moments-143.json's; and each factory has no code at its record's deployBlock − 1 and has it at
deployBlock. The two live factories are also pinned here (LIVE_LAUNCHPAD, LIVE_MOMENTS), as the keepers pin them
(LIVE_FACTORIES in contracts/keepers/lib/deployments.mjs): Swift and a record that agree on any other factory refuse on
every run, chain or not. Move the pins with the records when a new stack goes live.

`--release` also reads the public docs' Contracts & Addresses page, which Get Help opens, at the URL the app opens
(DyorKit's DocsLinks.contractsAndAddresses), with a plain HTTPS GET, and compares it with DyorKit's two tables (every
address, case-insensitive; the first LaunchpadFactory and MomentsFactory rows as the page reads). What it finds is a
note, never a refusal (owner decision 2026-10-01: the docs page doesn't gate a release, and some addresses are kept off
it on purpose): an address the page doesn't show, a retired factory it presents as current, or a page that can't be
read is printed for the release checklist, and the archive goes ahead.

`--chain-fixture FILE` is for DyorKit's RetiredCohortGateTests only: the chain checks alone (the retired cohorts, and the
live stacks when wired) and the docs check, against canned eth_call and eth_getCode answers and a canned page instead
of the chain and the docs site. It is refused together with `--release`.

Local config values are compared, never printed: a problem there names the key only.
"""
import json, os, re, sys, time, urllib.request
from html.parser import HTMLParser

ARGS = sys.argv[1:]
FLAGS = {"--release", "--chain", "--chain-fixture"}
FIXTURE = None
if "--chain-fixture" in ARGS:
    at = ARGS.index("--chain-fixture") + 1
    FIXTURE = ARGS[at] if at < len(ARGS) else None
    if FIXTURE is None:
        sys.exit("--chain-fixture needs a file")
    ARGS = ARGS[:at] + ARGS[at + 1:]
# An unknown flag is refused: a typo such as `--relase` must never run a plain check in place of the release gate.
if any(arg not in FLAGS for arg in ARGS):
    sys.exit(f"usage: {os.path.basename(__file__)} [--chain | --release]; unknown: {' '.join(a for a in ARGS if a not in FLAGS)}")
RELEASE = "--release" in ARGS
CHAIN = RELEASE or "--chain" in ARGS
if FIXTURE and RELEASE:
    sys.exit("REFUSING: --chain-fixture is for tests; a release reads the chain itself")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEPLOYMENTS = os.path.join(ROOT, "contracts/deployments")
record = json.load(open(os.path.join(DEPLOYMENTS, "143.json")))
moments_record = json.load(open(os.path.join(DEPLOYMENTS, "moments-143.json")))
KEYS = {  # record key → (xcconfig key, web env key, Swift field)
    "factory": ("LAUNCHPAD_FACTORY", "NEXT_PUBLIC_LAUNCHPAD_FACTORY", "factory"),
    "launchAndBuyRouter": ("LAUNCH_ROUTER", "NEXT_PUBLIC_LAUNCH_ROUTER", "router"),
    "escrow": ("FEE_ESCROW", "NEXT_PUBLIC_FEE_ESCROW", "escrow"),
    "holderFeeSharing": ("HOLDER_FEE_SHARING", "NEXT_PUBLIC_HOLDER_FEE_SHARING", "holderFeeSharing"),
    "hook": ("MEME_HOOK", "NEXT_PUBLIC_MEME_HOOK", "hook"),
}
MOMENTS_KEYS = {  # record key → (xcconfig key, Swift field)
    "factory": ("MOMENTS_FACTORY", "factory"),
    "collect": ("MOMENTS_COLLECT", "collect"),
    "vesting": ("MOMENTS_VESTING", "vesting"),
    "graduation": ("MOMENTS_GRADUATION", "graduation"),
    "locker": ("MOMENTS_LOCKER", "locker"),
    "hook": ("MOMENTS_HOOK", "hook"),
    "buyback": ("MOMENTS_BUYBACK", "buyback"),
    "platform": ("MOMENTS_PLATFORM", "platform"),
    "treasury": ("MOMENTS_TREASURY", "treasury"),
}
# The live factories while v2 is pending: the records are promoted only together with the Swift wiring.
PRE_V2_LAUNCHPAD = "0x6b1c8769a8d6745955ac35b91ff1f37ab76859db"
PRE_V2_MOMENTS = "0x0fd4ac52bbf387dbb3156805769bfc0c260f7e26"
# The live factories on Monad (the v2 release, 2026-09-28: launchpad v2 and Moments cohort 4), pinned as a second source
# like the keepers' LIVE_FACTORIES: a wired table and its record must both name them.
LIVE_LAUNCHPAD = "0x3b1f5f562f5f61b980abfddbebd6cdf9a73b0b5b"
LIVE_MOMENTS = "0x95eb7f5a88b10d9df32ac54f48c767927fa80840"
# Retired launchpad factories (the app launches nothing there and still serves their existing launches; 0x6B1C stays
# open on chain, owner decision 2026-09-28).
RETIRED_FACTORIES = {
    PRE_V2_LAUNCHPAD,
    "0x10f34a174d9c393a90aff94bded7e1db185446d7",
    "0x2f02972e166de71097eeac8303ce7fe6b6ebe9f4",
    "0xad3d3cb821279e52cfd499d15b26f77976eba1ea",
}
# Retired Moments factories (claim-only in the app).
RETIRED_MOMENTS_FACTORIES = {
    PRE_V2_MOMENTS,
    "0xc12b6b6948185cef75f861c5327702c30cb8a581",
    "0x64698c7702d85f87f43a6dff7d495cdd2327c020",
}
# The retired Moments factories that may stay open on chain (owner decision 2026-09-28): cohort 3 only. Every other one
# must be paused, as the keepers' OPEN_ON_CHAIN_MOMENTS also says.
OPEN_ON_CHAIN_MOMENTS = {PRE_V2_MOMENTS}
# Payout wallets retired in the 2026-09-23 relaunch. App code must never target them.
OLD_WALLETS = {
    "0x5282cc04f2f17cc296c5aefa2576c4c0327cf045": "leaked treasury",
    "0xf4d4baf60e5fcaf6a092b2d6b5509af9f01cfb48": "old fees wallet",
}
problems = []
notes = []  # informational, never a refusal

def swift_block(path):
    """The body of `static let monadMainnet = …(` up to its closing parenthesis."""
    swift = open(os.path.join(ROOT, path)).read()
    return swift.split("static let monadMainnet", 1)[1].split("\n    )", 1)[0]

def swift_fields(block, fields, where):
    """field → lowercase address, or "pending" for `field: .zero, // PENDING`; a problem for anything else."""
    out = {}
    for field in fields:
        literal = re.search(rf'\b{field}: Address\(literal: "(0x[0-9a-fA-F]{{40}})"\)', block)
        pending = re.search(rf'\b{field}: \.zero, // PENDING', block)
        if literal and not pending:
            out[field] = literal.group(1).lower()
        elif pending and not literal:
            out[field] = "pending"
        else:
            problems.append(f"{where}: {field} is neither an address literal nor `.zero, // PENDING`")
    return out

def state(values, where):
    """"pending" when every field is pending, "wired" when none is, else a problem (half a table)."""
    kinds = {v == "pending" for v in values.values()}
    if kinds == {True}:
        return "pending"
    if kinds == {False}:
        return "wired"
    if values:
        problems.append(f"{where} is partly wired: set every address, or none (PENDING)")
    return "broken"

# The retired Moments cohorts: MomentLink.Cohort's pins and MomentsAddresses.retiredMainnetCoins.
MOMENT_LINK = "ios/DyorKit/Sources/DyorKit/Services/Moments/MomentLink.swift"
MOMENTS_MODELS = "ios/DyorKit/Sources/DyorKit/Services/Moments/MomentsModels.swift"
# Keyless public Monad RPCs (docs.monad.xyz → Network information), tried in order; the last one that answered goes
# first. Only eth_blockNumber, eth_call and eth_getCode are sent. The deployBlock proof reads each factory's code at
# blocks weeks old, which only an endpoint with archive state answers: rpc1 (Alchemy, 15 rps), rpc2 (Goldsky Edge,
# 300 per 10 s) and the Monad Foundation's rpc-mainnet.monadinfra.com (20 rps) did on 2026-10-08, while rpc.monad.xyz
# (QuickNode, 25 rps) answers "historical state … not available" to them. rpc1 also refuses some clients outright
# (HTTP 403 by user agent, and Xcode Cloud's build 18 could read nothing at those blocks while this Mac could), so the
# archive-capable endpoints come first and every read gets RPC_ROUNDS tries over the whole list, a growing pause
# apart, before it counts as unreadable.
PUBLIC_RPCS = ["https://rpc1.monad.xyz", "https://rpc2.monad.xyz", "https://rpc-mainnet.monadinfra.com",
               "https://rpc.monad.xyz"]
RPC_ROUNDS = 3
RPC_PAUSE_S = 2.0
SELECTORS = {  # pinned in DyorKit's MomentsTests; RetiredCohortGateTests' fixture encodes every one with DyorKit's ABI
    "publishingPaused()": "0x788ab4ac",
    "momentCount()": "0xc895d059",
    "getMoment(uint256)": "0x557a2d20",
    # the live stacks' getters
    "owner()": "0x8da5cb5b",
    "modulesSealed()": "0x99571f57",
    "hook()": "0x7f5a7c7b",
    "escrow()": "0xe2fdcc17",
    "holderFeeSharing()": "0x3f81cafc",
    "router()": "0xf887ea40",
    "collect()": "0xe5225381",
    "vesting()": "0x44c63eec",
    "graduation()": "0xda4c9e00",
    "locker()": "0xd7b96d4e",
    "feeHook()": "0xf11f4461",
    "buyback()": "0xf8ec6911",
    "policy()": "0x0505c8c9",
    "externalBaseURI()": "0xae8d070b",
    "governance()": "0x5aa6e675",
    "guardian()": "0x452a9320",
}
POLICY_WORDS = 10  # MomentTypes.Policy, all static: (threshold, minPrice, 6 × bps, platform, treasury)
MOMENT_WORDS = 17  # MomentTypes.Moment, all static: (creator, platform, treasury, coin, nft, …); the coin is word 3
# How many Moments past a pin are read, to name their coins, when a cohort has grown.
PAST_PIN = 20
# MomentLink.Cohort.namedMomentCount: the retired cohorts' named Moments when c4 went live (build 16). Frozen: a changed
# count would move every name link after it.
NAMED_MOMENTS = {"c1": 3, "c2": 2, "c3": 1}
# The docs page Get Help's Contracts & Addresses row opens (DyorKit's DocsLinks.contractsAndAddresses, pinned by
# RetiredCohortGateTests), read at that same URL.
DOCS_CONTRACTS_PAGE = "https://dyorhq.gitbook.io/docs/resources/contracts-and-addresses"
# Where the shared contracts a table names (`poolManager: Uniswap.poolManager`) are defined.
CHAIN_CONSTANTS = "ios/DyorKit/Sources/DyorKit/Chain/Monad.swift"

def retired_tables():
    """([(cohort, factory, pin)] in publish order, {coin: (factory, id)}), read from the Swift sources; problems for
    anything that does not parse or does not agree."""
    link = open(os.path.join(ROOT, MOMENT_LINK)).read()
    factories = {c: a.lower() for c, a in re.findall(r'case \.(c\d+): return Address\(literal: "(0x[0-9a-fA-F]{40})"\)', link)}
    pins_body = re.search(r'var finalMomentCount: Int\? \{(.*?)\n        \}', link, re.S)
    pins = re.findall(r'case \.(c\d+): return (\d+|nil)\b', pins_body.group(1)) if pins_body else []
    cohorts = [(c, factories.get(c), int(pin)) for c, pin in pins if pin != "nil"]
    where = "MomentLink.Cohort"
    if not cohorts:
        problems.append(f"{where}: no retired cohort's finalMomentCount could be read from {MOMENT_LINK}")
    for c, factory, _ in cohorts:
        if not factory:
            problems.append(f"{where}.{c} is pinned but has no factory literal")
    for c, pin in pins:
        if pin == "nil" and c in factories:
            problems.append(f"{where}.{c} is counted live but has a factory literal (the live factory lives only in MomentsAddresses.monadMainnet)")
    if {f for _, f, _ in cohorts} != RETIRED_MOMENTS_FACTORIES:
        problems.append(f"{where}'s pinned cohorts are not exactly this script's RETIRED_MOMENTS_FACTORIES")
    named_body = re.search(r'var namedMomentCount: Int\? \{(.*?)\n        \}', link, re.S)
    named = {c: int(n) for c, n in re.findall(r'case \.(c\d+): return (\d+)\b', named_body.group(1))} if named_body else {}
    if named != NAMED_MOMENTS:
        problems.append(f"{where}.namedMomentCount is {named or 'unreadable'}, not the frozen {NAMED_MOMENTS}: a retired cohort's "
                        "names never change, or every later Moment's name link moves")
    for c, _, pin in cohorts:
        if named.get(c, 0) > pin:
            problems.append(f"{where}.{c} names {named[c]} Moments but finalMomentCount pins {pin}")

    models = open(os.path.join(ROOT, MOMENTS_MODELS)).read()
    body = re.search(r'static let retiredMainnetCoins: \[Address: MomentKey\] = \[(.*?)\n    \]', models, re.S)
    entries = re.findall(r'Address\(literal: "(0x[0-9a-fA-F]{40})"\): MomentKey\(factory: Address\(literal: "(0x[0-9a-fA-F]{40})"\), id: (\d+)\)',
                         body.group(1)) if body else []
    coins = {coin.lower(): (factory.lower(), int(i)) for coin, factory, i in entries}
    where = "MomentsAddresses.retiredMainnetCoins"
    if not body or body.group(1).count("MomentKey(") != len(entries) or len(coins) != len(entries):
        problems.append(f"{where}: every entry must read `Address(literal: \"0x…\"): MomentKey(factory: Address(literal: \"0x…\"), id: N)`, once per coin")
    for c, factory, pin in cohorts:
        ids = sorted(i for f, i in coins.values() if f == factory)
        if ids != list(range(1, pin + 1)):
            problems.append(f"{where} holds ids {ids} for cohort {c} ({factory}), whose finalMomentCount pins {pin}: one coin per Moment, #1…#{pin}")
    for coin, (factory, i) in coins.items():
        if factory not in RETIRED_MOMENTS_FACTORIES:
            problems.append(f"{where}: {coin} is keyed to {factory}, not a retired Moments factory")
    return cohorts, coins

def rpc(method, params):
    """A read from the first public RPC that answers (the last one that did goes first), over RPC_ROUNDS rounds of the
    whole list; raises, naming every answer of the last round, when none does."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    errors = []
    for round_number in range(RPC_ROUNDS):
        if round_number:
            time.sleep(RPC_PAUSE_S * round_number)
        errors = []
        for url in list(PUBLIC_RPCS):
            request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "dyorhq-release-gate"})
            try:
                reply = json.load(urllib.request.urlopen(request, timeout=20))
            except Exception as e:  # noqa: BLE001 — any transport failure (an HTTP status included) moves to the next RPC
                status = getattr(e, "code", None)  # an HTTPError's status, e.g. 403 or 429
                errors.append(f"{url}: {type(e).__name__}{f' {status}' if status else ''}")
                continue
            if "result" in reply:
                PUBLIC_RPCS.remove(url)
                PUBLIC_RPCS.insert(0, url)
                return reply["result"]
            errors.append(f"{url}: {str(reply.get('error'))[:120]}")
    raise RuntimeError("; ".join(errors))

def chain_reader():
    """(block, call, code): eth_calls pinned to one block, so every answer describes the same chain state, and the code
    at an address (at that block, or at the block given). A few blocks (~2 s) behind the head, so a fallback RPC that
    lags slightly still serves it."""
    block = int(rpc("eth_blockNumber", []), 16) - 5
    return (block, lambda to, data: rpc("eth_call", [{"to": to, "data": data}, hex(block)]),
            lambda address, at=None: rpc("eth_getCode", [address, hex(block if at is None else at)]))

def fixture_reader(path):
    """(block, call, code) answering from a test's canned answers: {"block": N, "calls": {"<to>:<calldata>": "0x…"},
    "code": {"<address>@<block>": "0x…"}}."""
    fixture = json.load(open(path))
    block = fixture.get("block", 0)
    calls = {k.lower(): v for k, v in fixture.get("calls", {}).items()}
    codes = {k.lower(): v for k, v in fixture.get("code", {}).items()}
    def answer(table, key):
        found = table.get(key.lower())
        if not isinstance(found, str):
            raise RuntimeError("no answer in the fixture")
        return found
    return (block, lambda to, data: answer(calls, f"{to}:{data}"),
            lambda address, at=None: answer(codes, f"{address}@{block if at is None else at}"))

def words(answer, count, what):
    data = bytes.fromhex(answer[2:] if answer.startswith("0x") else answer)
    if len(data) < 32 * count:
        raise ValueError(f"{what} returned {len(data)} bytes")
    return [int.from_bytes(data[32 * i:32 * (i + 1)], "big") for i in range(count)]

def check_retired_on_chain(cohorts, coins, call):
    """Each retired factory: momentCount() == its pin, its coins exactly its table entries, and publishing paused unless
    it is in OPEN_ON_CHAIN_MOMENTS. Returns the open cohorts of that set, which are reported, not refused (see the
    docstring)."""
    open_cohorts = []
    for c, factory, pin in cohorts:
        where = f"Moments cohort {c} ({factory})"
        try:
            paused = words(call(factory, SELECTORS["publishingPaused()"]), 1, "publishingPaused()")[0]
            count = words(call(factory, SELECTORS["momentCount()"]), 1, "momentCount()")[0]
            if paused > 1:
                raise ValueError(f"publishingPaused() returned {paused}")
            on_chain = {}
            for i in range(1, min(count, pin + PAST_PIN) + 1):
                coin = words(call(factory, SELECTORS["getMoment(uint256)"] + f"{i:064x}"), MOMENT_WORDS, f"getMoment({i})")[3]
                if coin == 0 or coin >> 160:
                    raise ValueError(f"getMoment({i}) has no coin")
                on_chain[f"0x{coin:040x}"] = i
        except Exception as e:  # noqa: BLE001 — unreadable is not proven final
            problems.append(f"{where} could not be read on chain ({type(e).__name__}: {str(e)[:160]}); it must be proven final before a release")
            continue
        if paused != 1 and factory.lower() in OPEN_ON_CHAIN_MOMENTS:
            open_cohorts.append(c)
            notes.append(f"{where}: publishing is open on chain (retired in the app only, owner decision 2026-09-28); "
                         f"momentCount() is {count}, pinned {pin}")
        elif paused != 1:
            problems.append(f"{where}: publishing is not paused on chain; a retired cohort other than cohort 3 must be paused "
                            "(setPublishingPaused(true)) before a release: its policy pays the retired wallets")
        if count != pin:
            problems.append(f"{where}: momentCount() is {count} on chain but MomentLink.Cohort.{c}.finalMomentCount pins {pin}: "
                            "a Moment was published there after the pin. Pin the new count and add every new coin to "
                            "MomentsAddresses.retiredMainnetCoins, so the app never trades it (the new Moment gets its id "
                            "link only: namedMomentCount stays, and no name link changes)")
        table = {coin: i for coin, (f, i) in coins.items() if f == factory}
        for coin, i in sorted(on_chain.items(), key=lambda kv: kv[1]):
            if table.get(coin) != i:
                problems.append(f"{where}: Moment #{i}'s coin {coin} is not in MomentsAddresses.retiredMainnetCoins as (factory, {i})")
        for coin, i in sorted(table.items(), key=lambda kv: kv[1]):
            if on_chain.get(coin) != i:
                problems.append(f"{where}: MomentsAddresses.retiredMainnetCoins names {coin} as #{i}, which the chain does not")
    return open_cohorts

def address_of(answer, what):
    word = words(answer, 1, what)[0]
    if word >> 160:
        raise ValueError(f"{what} returned no address")
    return f"0x{word:040x}"

def string_of(answer, what):
    """An ABI-encoded `string` return value."""
    data = bytes.fromhex(answer[2:] if answer.startswith("0x") else answer)
    offset = int.from_bytes(data[:32], "big") if len(data) >= 64 else None
    length = int.from_bytes(data[offset:offset + 32], "big") if offset is not None and offset + 32 <= len(data) else None
    if length is None or offset + 32 + length > len(data):
        raise ValueError(f"{what} returned {len(data)} bytes, not an ABI string")
    return data[offset + 32:offset + 32 + length].decode("utf-8")

def has_code(answer):
    return answer.strip().lower() not in ("", "0x")

def link_base():
    """MomentsAddresses.expectedExternalBaseURI, `https://<MomentLink.host>/moments/<Cohort.c4.rawValue>/`."""
    link = open(os.path.join(ROOT, MOMENT_LINK)).read()
    host = re.search(r'public static let host = "([a-z0-9.-]+)"', link)
    c4 = re.search(r'\bc4 = "([a-z0-9]+)"', link)
    if not host or not c4:
        problems.append(f"{MOMENT_LINK}: MomentLink.host or Cohort.c4's path segment could not be read")
        return None
    return f"https://{host.group(1)}/moments/{c4.group(1)}/"

def check_live_on_chain(call, code):
    """The live stacks as the chain has them (see the docstring): each factory's getters name the modules in DyorKit's
    tables and the record's owner, every module has code, and each factory was created at its record's deployBlock."""
    lp, mf = launchpad["factory"], moments["factory"]
    lp_where, mf_where = f"live launchpad factory {lp}", f"live Moments factory {mf}"
    swift_lp, swift_m = "LaunchpadAddresses.monadMainnet", "MomentsAddresses.monadMainnet"

    def read(where, contract, getter, decode):
        try:
            return decode(call(contract, SELECTORS[getter]), getter)
        except Exception as e:  # noqa: BLE001 — unreadable is not proven live
            problems.append(f"{where}: {getter} could not be read on chain ({type(e).__name__}: {str(e)[:160]}); "
                            "the live stacks must be proven before a release")
            return None

    # Every module the app calls has code (the platform and treasury are wallets); a factory without any is not read.
    modules = [(swift_lp, field, address) for field, address in launchpad.items()]
    modules += [(swift_m, field, address) for field, address in moments.items() if field not in ("platform", "treasury")]
    missing = set()
    for where, field, address in modules:
        try:
            if not has_code(code(address)):
                problems.append(f"{where}.{field} {address} has no code on chain")
                missing.add(address)
        except Exception as e:  # noqa: BLE001
            problems.append(f"{where}.{field} {address}: its code could not be read on chain ({type(e).__name__}: {str(e)[:200]}); refusing")
            missing.add(address)

    expected = [  # (where, contract, getter, value, whose)
        (lp_where, lp, "hook()", launchpad["hook"], swift_lp),
        (lp_where, lp, "escrow()", launchpad["escrow"], swift_lp),
        (lp_where, lp, "holderFeeSharing()", launchpad["holderFeeSharing"], swift_lp),
        (lp_where, lp, "router()", launchpad["router"], swift_lp),
        (lp_where, lp, "owner()", str(record.get("owner", "")).lower(), "143.json"),
        (mf_where, mf, "collect()", moments["collect"], swift_m),
        (mf_where, mf, "vesting()", moments["vesting"], swift_m),
        (mf_where, mf, "graduation()", moments["graduation"], swift_m),
        (mf_where, mf, "locker()", moments["locker"], swift_m),
        (mf_where, mf, "feeHook()", moments["hook"], swift_m),
        (mf_where, mf, "buyback()", moments["buyback"], swift_m),
        (mf_where, mf, "governance()", str(moments_record.get("governance", "")).lower(), "moments-143.json"),
        (mf_where, mf, "guardian()", str(moments_record.get("guardian", "")).lower(), "moments-143.json"),
    ]
    for where, contract, getter, want, whose in expected:
        got = None if contract in missing else read(where, contract, getter, address_of)
        if got is not None and got != want:
            problems.append(f"{where}: {getter} is {got} on chain, but {whose} says {want or 'nothing'}")
    if lp not in missing:
        sealed = read(lp_where, lp, "modulesSealed()", lambda answer, what: words(answer, 1, what)[0])
        if sealed is not None and sealed != 1:
            problems.append(f"{lp_where}: modulesSealed() is not true on chain, so its modules can still be replaced")
    if mf not in missing:
        policy = read(mf_where, mf, "policy()", lambda answer, what: words(answer, POLICY_WORDS, what))
        if policy is not None:
            for name, word in (("platform", policy[8]), ("treasury", policy[9])):
                if f"0x{word:040x}" != moments[name]:
                    problems.append(f"{mf_where}: policy() pays {name} 0x{word:040x}, but {swift_m} says {moments[name]} "
                                    "(the app refuses to publish there)")
        base, want_base = read(mf_where, mf, "externalBaseURI()", string_of), link_base()
        if base is not None and want_base is not None and base != want_base:
            problems.append(f"{mf_where}: externalBaseURI() is {base!r} on chain, but the c4 link base is {want_base!r}")

    # Each factory was created at its record's deployBlock: no code one block before, code at it.
    for where, factory, deploy_block, whose in ((lp_where, lp, record.get("deployBlock"), "143.json"),
                                                (mf_where, mf, moments_record.get("deployBlock"), "moments-143.json")):
        if factory in missing:
            continue
        if not isinstance(deploy_block, int) or deploy_block <= 0:
            problems.append(f"contracts/deployments/{whose} has no deployBlock")
            continue
        try:
            before, at = has_code(code(factory, deploy_block - 1)), has_code(code(factory, deploy_block))
        except Exception as e:  # noqa: BLE001
            problems.append(f"{where}: its code around {whose}'s deployBlock could not be read on chain ({type(e).__name__}: {str(e)[:200]}); refusing")
            continue
        if before or not at:
            problems.append(f"{where}: {whose}'s deployBlock {deploy_block} is not the block that created it "
                            f"(code at {deploy_block - 1}: {'yes' if before else 'no'}; at {deploy_block}: {'yes' if at else 'no'})")

def table_addresses(block, where):
    """Every address in a DyorKit table as (field, lowercase address): its literals, and the shared constants it names
    (`poolManager: Uniswap.poolManager`) read from CHAIN_CONSTANTS."""
    constants = open(os.path.join(ROOT, CHAIN_CONSTANTS)).read()
    out = []
    for field, literal, namespace, name in re.findall(
            r'^\s*(\w+): (?:Address\(literal: "(0x[0-9a-fA-F]{40})"\)|([A-Z]\w*)\.(\w+)),?\s*$', block, re.M):
        if not literal:
            body = re.search(rf'public enum {namespace} \{{(.*?)\n\}}', constants, re.S)
            found = body and re.search(rf'static let {name} = Address\(literal: "(0x[0-9a-fA-F]{{40}})"\)', body.group(1))
            if not found:
                problems.append(f"{where}.{field}: {namespace}.{name} could not be read from {CHAIN_CONSTANTS}")
                continue
            literal = found.group(1)
        out.append((field, literal.lower()))
    return out

class VisibleText(HTMLParser):
    """The text a reader sees on an HTML page: scripts, styles and templates left out."""
    HIDDEN = {"script", "style", "template", "noscript"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        self.hidden += tag in self.HIDDEN

    def handle_endtag(self, tag):
        if tag in self.HIDDEN and self.hidden:
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden and data.strip():
            self.parts.append(data.strip())

def docs_page():
    """The Contracts & Addresses page: the fixture's in tests, else the published one, fetched at the URL the app opens
    (a plain HTTPS GET, no auth)."""
    if FIXTURE:
        page = json.load(open(FIXTURE)).get("docs")
        if not isinstance(page, str):
            raise RuntimeError("no page in the fixture")
        return page
    request = urllib.request.Request(DOCS_CONTRACTS_PAGE, headers={"User-Agent": "dyorhq-release-gate"})
    with urllib.request.urlopen(request, timeout=20) as reply:
        return reply.read().decode("utf-8")

def check_docs_page():
    """Whether the published page shows every address in DyorKit's two tables, with the tables' factories as its
    current-release rows (a retired stack may follow, under previous releases). Each difference is a note, never a
    problem: the page doesn't gate a release (see the docstring). True when it matches."""
    where = f"the docs page {DOCS_CONTRACTS_PAGE}"
    try:
        page = docs_page()
    except Exception as e:  # noqa: BLE001 — unread is not proven
        notes.append(f"{where} could not be read ({type(e).__name__}: {str(e)[:160]}); not compared")
        return False
    before = len(notes)
    text = page.lower()
    listed = [(f"LaunchpadAddresses.monadMainnet.{field}", address) for field, address in launchpad_addresses]
    listed += [(f"MomentsAddresses.monadMainnet.{field}", address) for field, address in moments_addresses]
    missing = [f"{name} {address}" for name, address in listed if address not in text]
    if missing:
        notes.append(f"{where} does not list: {', '.join(missing)}")
    reader = VisibleText()
    reader.feed(page)
    shown = " ".join(reader.parts)
    for row, factory, table in (("LaunchpadFactory", launchpad["factory"], "LaunchpadAddresses.monadMainnet"),
                                ("MomentsFactory", moments["factory"], "MomentsAddresses.monadMainnet")):
        first = re.search(rf'\b{row}\b.*?(0x[0-9a-fA-F]{{40}})', shown, re.S)
        if not first:
            notes.append(f"{where} has no {row} row")
        elif first.group(1).lower() != factory:
            retired = " (a retired one)" if first.group(1).lower() in RETIRED_FACTORIES | RETIRED_MOMENTS_FACTORIES else ""
            notes.append(f"{where} presents {first.group(1)}{retired} as the current {row}, not {table}'s {factory}")
    return len(notes) == before

def report(ok_line):
    for note in notes:
        print(f"note: {note}")
    if problems:
        print("Launchpad / Moments check failed:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print(ok_line)

# DyorKit's launchpad constant
where = "DyorKit LaunchpadAddresses.monadMainnet"
block = swift_block("ios/DyorKit/Sources/DyorKit/Services/Launchpad/LaunchpadModels.swift")
launchpad = swift_fields(block, [field for (_, _, field) in KEYS.values()], where)
launchpad_addresses = table_addresses(block, where)
launchpad_state = state(launchpad, where)
if "generation: .v2" not in block:
    problems.append(f"{where} must be `generation: .v2`")
if launchpad_state == "wired":
    for key, (_, _, field) in KEYS.items():
        if launchpad.get(field) != record[key].lower():
            problems.append(f"{where}: {key} is {launchpad.get(field)}, deployment record says {record[key]}")
    if record["factory"].lower() in RETIRED_FACTORIES:
        problems.append(f"contracts/deployments/143.json: factory {record['factory']} is a retired launchpad")
    for name, factory in ((where, launchpad.get("factory")), ("contracts/deployments/143.json", record["factory"].lower())):
        if factory != LIVE_LAUNCHPAD:
            problems.append(f"{name}: factory is {factory}, not the live launchpad factory pinned here ({LIVE_LAUNCHPAD}); "
                            "a new stack moves this pin, the keepers' LIVE_FACTORIES and the records together")
elif launchpad_state == "pending" and record["factory"].lower() != PRE_V2_LAUNCHPAD:
    problems.append(f"contracts/deployments/143.json names {record['factory']} but {where} is PENDING: wire it in the same change")

# DyorKit's Moments constant
where = "DyorKit MomentsAddresses.monadMainnet"
block = swift_block("ios/DyorKit/Sources/DyorKit/Services/Moments/MomentsModels.swift")
moments = swift_fields(block, [field for (_, field) in MOMENTS_KEYS.values()], where)
moments_addresses = table_addresses(block, where)
deploy_block = re.search(r'\bdeployBlock: ([0-9_]+)(,? // PENDING)?', block)
moments_state = state(moments, where)
if "generation: .v2" not in block:
    problems.append(f"{where} must be `generation: .v2`")
if moments_state == "wired":
    for key, (_, field) in MOMENTS_KEYS.items():
        expected = str(moments_record.get(key, "")).lower()
        if moments.get(field) != expected:
            problems.append(f"{where}: {key} is {moments.get(field)}, deployment record says {moments_record.get(key)}")
    baked_block = int(deploy_block.group(1).replace("_", "")) if deploy_block else 0
    if moments_record.get("deployBlock") != baked_block or baked_block <= 107_311_600:
        problems.append(f"{where}: deployBlock is {baked_block}, deployment record says {moments_record.get('deployBlock')} (add it to the record by hand)")
    if moments_record["factory"].lower() in RETIRED_MOMENTS_FACTORIES:
        problems.append(f"contracts/deployments/moments-143.json: factory {moments_record['factory']} is a retired Moments cohort")
    for name, factory in ((where, moments.get("factory")), ("contracts/deployments/moments-143.json", moments_record["factory"].lower())):
        if factory != LIVE_MOMENTS:
            problems.append(f"{name}: factory is {factory}, not the live Moments factory pinned here ({LIVE_MOMENTS}); "
                            "a new stack moves this pin, the keepers' LIVE_FACTORIES and the records together")
elif moments_state == "pending":
    if not deploy_block or int(deploy_block.group(1).replace("_", "")) != 0:
        problems.append(f"{where} is PENDING but has a deployBlock")
    if moments_record["factory"].lower() != PRE_V2_MOMENTS:
        problems.append(f"contracts/deployments/moments-143.json names {moments_record['factory']} but {where} is PENDING: wire it in the same change")

if RELEASE:
    for name, st in (("LaunchpadAddresses.monadMainnet", launchpad_state), ("MomentsAddresses.monadMainnet", moments_state)):
        if st != "wired":
            problems.append(f"REFUSING TO SHIP: DyorKit {name} (v2) is {st.upper()}; wire the v2 addresses first")

# The retired Moments cohorts: the pins and the coin table always; the chain with --chain / --release, and the live
# stacks on chain with them once both are wired.
retired_cohorts, retired_coins = retired_tables()
chain_block = None
open_cohorts = []
live_checked = False
reader = None
if FIXTURE:
    reader = fixture_reader(FIXTURE)
elif CHAIN:
    try:
        reader = chain_reader()
    except Exception as e:  # noqa: BLE001
        problems.append(f"no public Monad RPC answered ({str(e)[:200]}), so the retired Moments cohorts and the live stacks cannot be proven; refusing")
if reader:
    chain_block, call, code = reader
    open_cohorts = check_retired_on_chain(retired_cohorts, retired_coins, call)
    if launchpad_state == moments_state == "wired":
        check_live_on_chain(call, code)
        live_checked = True
docs_checked = (RELEASE or FIXTURE) and launchpad_state == moments_state == "wired"
docs_match = check_docs_page() if docs_checked else False

if FIXTURE:
    # Tests only: the chain checks against canned answers (never with --release, and no local config; see the docstring).
    report(f"OK: retired Moments cohorts at their pins at fixture block {chain_block} ({', '.join(f'{c} {pin}' for c, _, pin in retired_cohorts)})"
           + (f"; publishing open on {', '.join(open_cohorts)}" if open_cohorts else "")
           + ("; live stacks as wired" if live_checked else "")
           + (("; docs page lists them" if docs_match else "; docs page differs (noted)") if docs_checked else ""))
    sys.exit(0)

# Local overrides, when present. An xcconfig/env that sets the keys must set them to the current deployment
# (or point at a fork on purpose — then this script is expected to complain).
def kv_file(path, pattern):
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        m = re.match(pattern, line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out

def check_local(where, key, expected, value):
    # Local config files are gitignored and sit next to secrets: name the key, never echo the value.
    if value is not None and value.lower() != str(expected).lower():
        problems.append(f"{where}: {key} does not match the deployment record")

xc = kv_file(os.path.join(ROOT, "ios/DyorHQ/Config/Secrets.xcconfig"), r"^([A-Z_]+)\s*=\s*(.+)$")
for key, (xkey, _, _) in KEYS.items():
    check_local("ios Secrets.xcconfig", key, record[key], xc.get(xkey))
for key, (xkey, _) in MOMENTS_KEYS.items():
    check_local("ios Secrets.xcconfig", f"moments {key}", moments_record.get(key, ""), xc.get(xkey))
# Script env files: compared by key name, values never printed (the same files hold private keys).
def env_value(raw):
    return raw.split(" #", 1)[0].strip().strip("'\"").lower()

envs = {}
for name in (".env", ".env.local"):
    env = kv_file(os.path.join(ROOT, name), r"^(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)$")
    if not env:
        continue
    envs[name] = env
    for key, (_, ekey, _) in KEYS.items():
        if ekey not in env:
            continue
        value = env_value(env[ekey])
        if value != record[key].lower():
            retired = " (a retired launchpad factory)" if value in RETIRED_FACTORIES else ""
            problems.append(f"{name}: {ekey} does not match the deployment record's {key}{retired}")
    for ekey, raw in env.items():
        label = OLD_WALLETS.get(env_value(raw))
        if label:
            problems.append(f"{name}: {ekey} holds the {label}")

active = [k for k in list(KEYS.values()) + list(MOMENTS_KEYS.values()) if k[0] in xc]
summary = ", ".join(f"{name} {st}" for name, st in (("launchpad v2", launchpad_state), ("Moments v2", moments_state)))
pins = ", ".join(f"{c} {pin}" for c, _, pin in retired_cohorts)
if chain_block is None:
    retired = f"; retired Moments pins {pins} (not checked on chain: --chain)"
else:
    opened = f"; publishing open on {', '.join(open_cohorts)}" if open_cohorts else ", publishing paused"
    retired = f"; retired Moments cohorts at their pins on chain at block {chain_block} ({pins}{opened})"
report(f"OK: DyorKit ({summary})"
       + (", Secrets.xcconfig" if active else ", Secrets.xcconfig (no override)")
       + "".join(f", {name}" for name in envs)
       + f"; live records: factory {record['factory']}, Moments factory {moments_record['factory']}"
       + (" (on chain as wired)" if live_checked else "")
       + (("; the docs page lists them" if docs_match else "; the docs page differs (noted)") if docs_checked else "")
       + retired)
