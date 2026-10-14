#!/usr/bin/env python3
"""Byte-for-byte code parity between a retired stack and the stack that replaces it.

For every contract named by <keys> in both deployment records, the retired contract's runtime code — with each of the
retired stack's own addresses swapped for its replacement (constructor immutables like `factory`) — must equal the new
contract's runtime code exactly. Equal code means the relaunch runs precisely the audited, battle-tested source.
LaunchDeployer's constructor-created CurveDeployer is included automatically.
Usage: parity.py <rpc> <old.json> <new.json> <key>...
"""
import json, os, subprocess, sys

CAST = os.path.expanduser("~/.foundry/bin/cast")


def cast(*args):
    out = subprocess.run([CAST, *args], capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(f"cast {args[0]}: {out.stderr.strip()[:200]}")
    return out.stdout.strip()


def main():
    rpc, old_path, new_path, keys = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    old, new = json.load(open(old_path)), json.load(open(new_path))
    pairs = [(k, old[k], new[k]) for k in keys]
    if "launchDeployer" in keys:
        getter = "curveDeployer()(address)"
        pairs.append(("curveDeployer", cast("call", old["launchDeployer"], getter, "--rpc-url", rpc), cast("call", new["launchDeployer"], getter, "--rpc-url", rpc)))
    swap = {o[2:].lower(): n[2:].lower() for _, o, n in pairs}
    ok = True
    for name, o, n in pairs:
        if o.lower() == n.lower():
            print(f"     !! {name}: the new record still names the retired contract {o}")
            ok = False
            continue
        oc, nc = cast("code", o, "--rpc-url", rpc).lower(), cast("code", n, "--rpc-url", rpc).lower()
        if len(nc) <= 2:
            print(f"     !! {name}: no code at {n}")
            ok = False
            continue
        swapped = oc
        for a, b in swap.items():
            swapped = swapped.replace(a, b)
        same = swapped == nc
        ok = ok and same
        print(f"     {'ok' if same else '!!'} {name:<19} {(len(nc) - 2) // 2:>6} bytes  {'identical' if same else 'DIFFERS'} ({o} → {n})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
