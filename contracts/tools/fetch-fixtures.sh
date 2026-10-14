#!/usr/bin/env bash
# STELLAR_RPC_URL=<rpc-url> fetch-fixtures.sh [name=]<contract-id>...
# fetch-fixtures.sh [name=]<contract-id>... < <file holding the RPC URL on its first line>
#
# Downloads the WASM behind each contract into contracts/testdata/<name>.wasm and records it in
# contracts/testdata/fixtures.json (DESIGN-stellar-contracts-v2 §18.3): {file, contract_id, wasm_hash, sha256,
# network, fetched_at, ledger, notes}. The file is created when missing, and other entries are kept. A re-fetch of
# a contract id already recorded under that file merges the new fields over the old entry, so the keys added by hand
# (notes, role, the venue records) survive; a new contract id replaces the entry and starts with empty notes.
#
# Read-only and keyless: two getLedgerEntries calls through the given RPC, one for the contracts' instances and one
# for the code entries their WASM hashes name. Nothing is signed or submitted.
#
#   STELLAR_RPC_URL=https://soroban-testnet.stellar.org contracts/tools/fetch-fixtures.sh \
#     aquarius_router=CBCFTQSPDBAIZ6R6PJQKSQWKNKWH2QIV3I4J72SHWBIK3ADRRAM5A6GD
#
# <name> is [A-Za-z0-9_]{1,64} and defaults to the contract id. FIXTURES_DIR overrides the output directory.
# The RPC URL comes from STELLAR_RPC_URL or, when that is unset, from the first line of stdin; never from an
# argument, so it doesn't appear in the process list. It is never printed or recorded either (curl's errors are
# reduced to their kind), so a keyed provider URL can't reach a log or a committed file. It must be https, or http on
# localhost.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 2
fi
command -v curl >/dev/null || { echo "fetch-fixtures: curl is required" >&2; exit 1; }

if [ -z "${STELLAR_RPC_URL:-}" ]; then
  if [ -t 0 ]; then
    echo "fetch-fixtures: set STELLAR_RPC_URL or pass the RPC URL on stdin" >&2
    exit 2
  fi
  IFS= read -r STELLAR_RPC_URL || true
fi
export STELLAR_RPC_URL

FIXTURES_DIR=${FIXTURES_DIR:-"$(cd "$(dirname "$0")/.." && pwd)/testdata"}
export FIXTURES_DIR

exec python3 -I - "$@" <<'PY'
import base64, datetime, hashlib, json, os, re, struct, subprocess, sys

NETWORKS = {
    "Test SDF Network ; September 2015": "testnet",
    "Public Global Stellar Network ; September 2015": "mainnet",
    "Test SDF Future Network ; October 2022": "futurenet",
}

# XDR discriminants (Stellar-ledger-entries.x, Stellar-contract.x).
LEDGER_ENTRY_CONTRACT_DATA = 6
LEDGER_ENTRY_CONTRACT_CODE = 7
SC_ADDRESS_TYPE_CONTRACT = 1
SCV_CONTRACT_INSTANCE = 19
SCV_LEDGER_KEY_CONTRACT_INSTANCE = 20
DURABILITY_PERSISTENT = 1
EXECUTABLE_WASM = 0
EXECUTABLE_STELLAR_ASSET = 1


def die(msg):
    print(f"fetch-fixtures: {msg}", file=sys.stderr)
    sys.exit(1)


def rpc(url, method, params=None):
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params

    def quoted(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

    # The URL and the body go to curl on stdin, so the URL never appears in the process list.
    config = "\n".join([
        "url = " + quoted(url),
        'header = "Content-Type: application/json"',
        "data-binary = " + quoted(json.dumps(body)),
        "",
    ])
    r = subprocess.run(["curl", "-sS", "--fail", "--max-time", "60", "--config", "-"],
                       input=config.encode(), capture_output=True)
    if r.returncode != 0:
        die(f"{method}: request failed ({curl_failure(r.returncode, r.stderr)})")
    try:
        resp = json.loads(r.stdout)
    except ValueError:
        die(f"{method}: the RPC answered with something other than JSON")
    if "error" in resp:
        die(f"{method}: {resp['error'].get('message', resp['error'])}")
    return resp["result"]


# curl's messages name the host, the port or the URL (resolve, connect, TLS), so only the kind of failure is shown.
CURL_FAILURES = {
    5: "could not resolve the proxy",
    6: "could not resolve the RPC host",
    7: "could not connect to the RPC",
    28: "timed out",
    35: "TLS handshake failed",
    52: "empty reply",
    56: "connection reset",
    60: "TLS certificate not trusted",
}


def curl_failure(code, stderr):
    if code == 22:
        status = re.search(r"error: (\d{3})", stderr.decode(errors="replace"))
        return f"HTTP {status.group(1)}" if status else "HTTP error"
    return CURL_FAILURES.get(code, f"curl exit {code}")


def crc16_xmodem(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def contract_hash(cid):
    """The 32-byte id inside a C... strkey (version byte 2 << 3, CRC16-XModem little-endian)."""
    if not re.fullmatch(r"C[A-Z2-7]{55}", cid):
        die(f"{cid}: not a contract id (C followed by 55 base32 characters)")
    raw = base64.b32decode(cid)
    if raw[0] != 2 << 3 or struct.pack("<H", crc16_xmodem(raw[:33])) != raw[33:]:
        die(f"{cid}: bad contract id checksum")
    return raw[1:33]


def u32(n):
    return struct.pack(">I", n)


def instance_key(h):
    return base64.b64encode(u32(LEDGER_ENTRY_CONTRACT_DATA) + u32(SC_ADDRESS_TYPE_CONTRACT) + h
                            + u32(SCV_LEDGER_KEY_CONTRACT_INSTANCE) + u32(DURABILITY_PERSISTENT)).decode()


def code_key(h):
    return base64.b64encode(u32(LEDGER_ENTRY_CONTRACT_CODE) + h).decode()


class Reader:
    def __init__(self, b64, what):
        self.b, self.i, self.what = base64.b64decode(b64), 0, what

    def take(self, n):
        if self.i + n > len(self.b):
            die(f"{self.what}: truncated entry")
        out = self.b[self.i:self.i + n]
        self.i += n
        return out

    def u32(self):
        return struct.unpack(">I", self.take(4))[0]

    def expect(self, value, field):
        got = self.u32()
        if got != value:
            die(f"{self.what}: unexpected {field} {got} (want {value})")

    def opaque(self):
        n = self.u32()
        out = self.take(n)
        self.take((4 - n % 4) % 4)
        return out


def wasm_hash_of_instance(xdr, cid, h):
    """ContractDataEntry {ext, contract, key, durability, val: SCV_CONTRACT_INSTANCE {executable, storage}}."""
    r = Reader(xdr, cid)
    r.expect(LEDGER_ENTRY_CONTRACT_DATA, "entry type")
    r.expect(0, "extension")
    r.expect(SC_ADDRESS_TYPE_CONTRACT, "address type")
    if r.take(32) != h:
        die(f"{cid}: the RPC returned another contract's instance")
    r.expect(SCV_LEDGER_KEY_CONTRACT_INSTANCE, "key type")
    r.expect(DURABILITY_PERSISTENT, "durability")
    r.expect(SCV_CONTRACT_INSTANCE, "value type")
    executable = r.u32()
    if executable == EXECUTABLE_STELLAR_ASSET:
        die(f"{cid}: a Stellar Asset Contract has no WASM to fetch")
    if executable != EXECUTABLE_WASM:
        die(f"{cid}: unknown executable type {executable}")
    return r.take(32)


def code_of_entry(xdr, what, wasm_hash):
    """ContractCodeEntry {ext (v0, or v1 with cost inputs), hash, code}."""
    r = Reader(xdr, what)
    r.expect(LEDGER_ENTRY_CONTRACT_CODE, "entry type")
    ext = r.u32()
    if ext == 1:
        r.expect(0, "extension")
        r.expect(0, "cost inputs extension")
        r.take(10 * 4)
    elif ext != 0:
        die(f"{what}: unknown code entry extension {ext}")
    if r.take(32) != wasm_hash:
        die(f"{what}: the RPC returned another code entry")
    code = r.opaque()
    if hashlib.sha256(code).digest() != wasm_hash:
        die(f"{what}: the code doesn't hash to its WASM hash")
    return code


def entries(url, keys, what):
    result = rpc(url, "getLedgerEntries", {"keys": keys})
    found = {e["key"]: e["xdr"] for e in result.get("entries") or []}
    missing = [k for k in keys if k not in found]
    if missing:
        die(f"{len(missing)} {what} not found (wrong network, or archived?)")
    return found, result.get("latestLedger")


def write_atomically(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def main(specs):
    url = os.environ.pop("STELLAR_RPC_URL", "").strip()
    if not url:
        die("no RPC URL: set STELLAR_RPC_URL or pass it on stdin")
    if re.search(r"[\s\x00-\x1f\x7f]", url):
        die("the RPC URL holds whitespace or a control character")
    if not (url.startswith("https://") or re.match(r"http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(/|$)", url)):
        die("the RPC URL must be https (or http on localhost)")
    targets = []
    for spec in specs:
        name, _, cid = spec.rpartition("=")
        name = name or cid
        if not re.fullmatch(r"[A-Za-z0-9_]{1,64}", name):
            die(f"{name}: a fixture name is [A-Za-z0-9_]{{1,64}}")
        if any(t[0] == name for t in targets):
            die(f"{name}: named twice")
        targets.append((name, cid, contract_hash(cid)))

    out_dir = os.environ["FIXTURES_DIR"]
    os.makedirs(out_dir, exist_ok=True)
    network = NETWORKS.get(rpc(url, "getNetwork").get("passphrase"), "custom")

    instances, _ = entries(url, [instance_key(h) for _, _, h in targets], "contract instance(s)")
    hashes = {name: wasm_hash_of_instance(instances[instance_key(h)], cid, h) for name, cid, h in targets}
    codes, ledger = entries(url, sorted({code_key(w) for w in hashes.values()}), "code entr(y/ies)")

    manifest = os.path.join(out_dir, "fixtures.json")
    doc = {}
    if os.path.exists(manifest):
        with open(manifest) as f:
            doc = json.load(f)
        if not isinstance(doc, dict) or not isinstance(doc.get("fixtures", []), list):
            die("fixtures.json: expected an object with a \"fixtures\" list")
    fixtures = doc.setdefault("fixtures", [])
    fetched_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for name, cid, _ in targets:
        wasm_hash = hashes[name]
        code = code_of_entry(codes[code_key(wasm_hash)], cid, wasm_hash)
        file = f"{name}.wasm"
        write_atomically(os.path.join(out_dir, file), code)
        old = next((f for f in fixtures if f.get("file") == file), None)
        record = {
            "file": file,
            "contract_id": cid,
            "wasm_hash": wasm_hash.hex(),
            "sha256": hashlib.sha256(code).hexdigest(),
            "network": network,
            "fetched_at": fetched_at,
            "ledger": ledger,
        }
        if old is not None and old.get("contract_id") == cid:
            record = {**old, **record}
        record.setdefault("notes", "")
        if old is None:
            fixtures.append(record)
        else:
            fixtures[fixtures.index(old)] = record
        print(f"{file}: {cid} ({network}), wasm {wasm_hash.hex()}, {len(code)} bytes")

    write_atomically(manifest, (json.dumps(doc, indent=2) + "\n").encode())
    print(f"recorded {len(targets)} fixture(s) in {manifest}")


main(sys.argv[1:])
PY
