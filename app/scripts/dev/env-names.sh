#!/bin/bash
# Names-only view of an env/xcconfig file: prints each variable NAME with its value's length and shape, never the
# value. Safe to run from Claude (the secret-file guard, .claude/hooks/secret-guard.py, allows it).
#   scripts/dev/env-names.sh .env
#   scripts/dev/env-names.sh ios/DyorHQ/Config/Secrets.xcconfig
set +x
[ -f "$1" ] || { echo "env-names: no such file: $1" >&2; exit 2; }
python3 - "$1" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    s = line.strip()
    if not s or s.startswith("#") or s.startswith("//"):
        continue
    m = re.match(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])*\s*=\s*(.*)$", s)
    if not m:
        continue
    name, val = m.group(1), m.group(3).strip().strip("'\"")
    if not val:
        shape = "empty"
    elif re.fullmatch(r"0x[0-9a-fA-F]{40}", val):
        shape = "address"
    elif re.fullmatch(r"(0x)?[0-9a-fA-F]{64}", val):
        shape = "32-byte hex"
    elif re.match(r"^[a-z]+://", val) or "$(DYOR_SLASH)" in val:
        shape = "url"
    else:
        shape = "text"
    print(f"{name}\tlen={len(val)}\t{shape}")
PY
