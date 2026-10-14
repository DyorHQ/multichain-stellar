#!/usr/bin/env python3
"""Live USD prices for the launchpad's volatile quote assets, from two independent sources each.

  MON : the deepest hookless Uniswap v4 MON/USDC pool on Monad (on-chain spot)  vs  CoinGecko "monad"
  aBIL: the Monday Trade aBIL/USDC 0.3% pool (on-chain spot)                    vs  CoinGecko tokenized ABIL

The on-chain value is the one used; the off-chain source must agree within MAX_SPREAD or nothing is printed and the
exit code is 1. Human-readable lines go to stderr; the last stdout line is `MON_USD_E8=<int> ABIL_USD_E8=<int>`.
Usage: prices.py <rpc-url>
"""
import json, os, subprocess, sys, time, urllib.request

CAST = os.path.expanduser("~/.foundry/bin/cast")
RPC = sys.argv[1] if len(sys.argv) > 1 else "https://rpc1.monad.xyz"
MAX_SPREAD = 0.02  # 2%
MAX_AGE_S = 3600  # CoinGecko quote must be under an hour old

ZERO = "0x0000000000000000000000000000000000000000"
USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
ABIL = "0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f"
STATE_VIEW = "0x77395f3b2e73ae90843717371294fa97cc419d64"  # Uniswap v4 StateView on Monad
ABIL_POOL = "0xb8700E0D0Df2B0b09A1374FbCdCC85E2E14F7898"  # Monday Trade aBIL/USDC fee 3000
CG_IDS = {"MON": "monad", "aBIL": "spdr-bloomberg-1-3-month-t-bill-etf-anchored-tokenized-etf"}
BANDS = {"MON": (0.005, 0.20), "aBIL": (50.0, 150.0)}


def log(*a):
    print(*a, file=sys.stderr)


def cast(*args):
    out = subprocess.run([CAST, *args], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(f"cast {' '.join(args[:2])}: {out.stderr.strip()[:200]}")
    return out.stdout.strip()


def first_int(s):
    return int(s.split()[0])


def mon_onchain():
    best = None
    for fee, spacing in ((500, 10), (3000, 60), (10000, 200)):
        enc = cast("abi-encode", "f(address,address,uint24,int24,address)", ZERO, USDC, str(fee), str(spacing), ZERO)
        pid = cast("keccak", enc)
        sqrt_p = first_int(cast("call", STATE_VIEW, "getSlot0(bytes32)(uint160,int24,uint24,uint24)", pid, "--rpc-url", RPC).splitlines()[0])
        liq = first_int(cast("call", STATE_VIEW, "getLiquidity(bytes32)(uint128)", pid, "--rpc-url", RPC))
        if sqrt_p and (best is None or liq > best[0]):
            best = (liq, fee, (sqrt_p / 2**96) ** 2 * 1e18 / 1e6)  # USDC (6dp) per MON (18dp)
    if best is None:
        raise RuntimeError("no initialized v4 MON/USDC pool")
    log(f"  MON  on-chain : ${best[2]:.8f}  (Uniswap v4 MON/USDC fee {best[1]}, liquidity {best[0]})")
    return best[2]


def abil_onchain():
    t0 = cast("call", ABIL_POOL, "token0()(address)", "--rpc-url", RPC)
    t1 = cast("call", ABIL_POOL, "token1()(address)", "--rpc-url", RPC)
    if t0.lower() != ABIL.lower() or t1.lower() != USDC.lower():
        raise RuntimeError(f"unexpected aBIL pool tokens {t0}/{t1}")
    sqrt_p = first_int(cast("call", ABIL_POOL, "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)", "--rpc-url", RPC).splitlines()[0])
    liq = first_int(cast("call", ABIL_POOL, "liquidity()(uint128)", "--rpc-url", RPC))
    if liq == 0:
        raise RuntimeError("aBIL pool has no active liquidity")
    price = (sqrt_p / 2**96) ** 2 * 1e18 / 1e6  # USDC (6dp) per aBIL (18dp)
    log(f"  aBIL on-chain : ${price:.6f}  (Monday Trade aBIL/USDC 0.3%, liquidity {liq})")
    return price


def coingecko():
    url = "https://api.coingecko.com/api/v3/simple/price?ids=" + ",".join(CG_IDS.values()) + "&vs_currencies=usd&include_last_updated_at=true"
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"user-agent": "dyorhq-relaunch/1.0", "accept": "application/json"})
            data = json.load(urllib.request.urlopen(req, timeout=15))
            out = {}
            for sym, cid in CG_IDS.items():
                row = data[cid]
                age = time.time() - row["last_updated_at"]
                if age > MAX_AGE_S:
                    raise RuntimeError(f"CoinGecko {sym} quote is {age/60:.0f} min old")
                out[sym] = float(row["usd"])
                log(f"  {sym:<4} CoinGecko: ${out[sym]:.8f}  ({age/60:.0f} min old)")
            return out
        except Exception as e:  # noqa: BLE001 — retry transient HTTP errors, then give up
            log(f"  CoinGecko attempt {attempt + 1} failed: {e}")
            time.sleep(3 * (attempt + 1))
    raise RuntimeError("CoinGecko unavailable — rerun in a minute")


def main():
    try:
        onchain = {"MON": mon_onchain(), "aBIL": abil_onchain()}
        offchain = coingecko()
    except Exception as e:  # noqa: BLE001
        log(f"!! price fetch failed: {e}")
        return 1
    ok = True
    for sym in ("MON", "aBIL"):
        a, b = onchain[sym], offchain[sym]
        spread = abs(a - b) / b
        lo, hi = BANDS[sym]
        verdict = "OK" if spread <= MAX_SPREAD and lo <= a <= hi else "MISMATCH"
        log(f"  {sym:<4} spread {spread * 100:.2f}% (max {MAX_SPREAD * 100:.0f}%)  band ${lo}–${hi}  -> {verdict}")
        ok = ok and verdict == "OK"
    if not ok:
        log("!! the two sources disagree (or a price is outside its sanity band) — not deploying on a bad price")
        return 1
    print(f"MON_USD_E8={round(onchain['MON'] * 1e8)} ABIL_USD_E8={round(onchain['aBIL'] * 1e8)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
