#!/usr/bin/env python3
"""Checks the Stellar screens' text: each key in its own table and translated, and the App Store catalog unchanged.

The internal build writes what each source looks up, and in which table, to a .stringsdata file per source
(SWIFT_EMIT_LOC_STRINGS). This script reads what the Lite code looks up: every source under ios/DyorHQ/Lite, and the
#if STELLAR_LITE blocks of the app's other sources (the lines check-build23.py strips). It fails when:
  1. a key of the Lite table or of a Stellar* table (StellarHome, …) is missing from
     ios/Internal/Resources/<table>.xcstrings, or isn't translated into every language the app ships;
  2. a translation changes a name that is never translated (Stellar, Monad, XLM, Freighter, …);
  3. a key of the default table (Text("…") or LocalizedStringResource("…") without a table) isn't one of the base's
     ios/DyorHQ/Resources/Localizable.xcstrings: the App Store catalog never gains a key, so new text names its table;
  4. a source uses any other table;
  5. with --enforce, a Lite or Stellar* table holds a key the Lite code doesn't use (listed, without failing,
     otherwise).

From ios/, after building DyorHQInternal.xcodeproj into <DerivedData>, with Python's isolated mode:
    python3 -I Internal/check-lite-strings.py --derived <DerivedData> --base d387a64
    python3 -I Internal/check-lite-strings.py --derived <DerivedData> --base d387a64 --enforce

Prints tables, keys and paths, never anything secret: catalogs hold UI text only. Exits 0 when clean, 1 on any
finding, 2 when it can't run (no build of the current sources, no base).
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
LITE = IOS / "DyorHQ" / "Lite"
TABLES = IOS / "Internal" / "Resources"
DEFAULT_TABLE = "Localizable"
LITE_TABLE = re.compile(r"Lite|Stellar\w+")
SOURCE = "en"
NEVER_TRANSLATED = ["Stellar", "Monad", "DyorHQ", "XLM", "USDC", "EURC", "Soroswap", "Aquarius", "Blend", "Circle CCTP",
                    "Freighter", "StellarExpert"]

findings = []
unused = []


def fail(where, message):
    findings.append(f"{where}: {message}")


def stop(message):
    print(f"check-lite-strings: {message}", file=sys.stderr)
    sys.exit(2)


def shipped_languages():
    """The languages the app ships other than English (CFBundleLocalizations in ios/project.yml)."""
    match = re.search(r"^\s*CFBundleLocalizations:\s*\[([^\]]*)\]", (IOS / "project.yml").read_text(encoding="utf-8"),
                      re.M)
    if not match:
        stop("no CFBundleLocalizations in ios/project.yml: the shipped languages are unknown")
    return [code.strip().strip("'\"") for code in match.group(1).split(",") if code.strip() not in ("", SOURCE)]


def units(localization):
    """Every (label, stringUnit) of one language's entry: the plain one and each plural or device variation."""
    out = []
    if "stringUnit" in localization:
        out.append(("", localization["stringUnit"]))
    for axis, cases in (localization.get("variations") or {}).items():
        for case, value in cases.items():
            out.extend((f" [{axis}={case}{label}]", unit) for label, unit in units(value))
    return out


def lite_code():
    """{source: the lines of it only the internal build compiles, or None for all}: every source under ios/DyorHQ/Lite,
    and the #if STELLAR_LITE blocks of the app's other sources, as check-build23.py strips them."""
    spec = importlib.util.spec_from_file_location("check_build23", Path(__file__).with_name("check-build23.py"))
    build23 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build23)
    code = {}
    for path in sorted((IOS / "DyorHQ").rglob("*.swift")):
        if LITE in path.parents:
            code[path] = None
            continue
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        if "STELLAR_LITE" not in text:
            continue
        try:
            _, kept = build23.strip(text)
        except build23.Unsupported as error:
            fail(f"{path.relative_to(IOS.parent)}:{error.line}", str(error))
            continue
        code[path] = set(range(1, text.count("\n") + 2)) - set(kept)
    return code


def used_keys(derived):
    """{table: {key: where the Lite code uses it first}}, from the internal build's .stringsdata."""
    code = lite_code()
    sources = {os.path.realpath(path): path for path in code}
    found = {}
    pattern = "Build/Intermediates.noindex/DyorHQInternal.build/*/DyorHQ.build/Objects-normal/*/*.stringsdata"
    for data in derived.glob(pattern):
        try:
            extracted = json.loads(data.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            stop(f"{data} is not a readable .stringsdata")
        source = sources.get(os.path.realpath(extracted.get("source", "")))
        if source is not None:
            found.setdefault(source, []).append((data, extracted.get("tables") or {}))

    used, stale = {}, []
    for source in sorted(sources.values()):
        where = source.relative_to(IOS.parent)
        fresh = [tables for data, tables in found.get(source, []) if data.stat().st_mtime >= source.stat().st_mtime]
        if not fresh:
            stale.append(str(where))
            continue
        for tables in fresh:
            for table, entries in tables.items():
                for entry in entries:
                    line = (entry.get("location") or {}).get("startingLine")
                    if code[source] is None or line in code[source]:
                        used.setdefault(table, {}).setdefault(entry["key"], f"{where}:{line}" if line else str(where))
    if stale:
        stop(f"no .stringsdata newer than {', '.join(stale)} under {derived}: build DyorHQInternal.xcodeproj into it "
             "first (Debug)")
    return used


def load_catalog(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("strings") or {}
    except (OSError, ValueError):
        stop(f"{path} is not a readable String Catalog")


def check_lite_key(table, key, entry, where, shipped):
    if entry.get("shouldTranslate") is False:
        return
    localizations = entry.get("localizations") or {}
    english = [unit.get("value", "") for _, unit in units(localizations.get(SOURCE, {}))] or [key]
    names = [name for name in NEVER_TRANSLATED if re.search(rf"\b{re.escape(name)}\b", english[-1])]
    for language in shipped:
        found = units(localizations.get(language, {}))
        if not found:
            fail(f"{table}: {key!r} ({where})", f"no {language} translation")
            continue
        for label, unit in found:
            value = unit.get("value", "")
            if unit.get("state") != "translated" or not value.strip():
                state = "empty" if unit.get("state") == "translated" else f"state is {unit.get('state')!r}"
                fail(f"{table}: {key!r} {language}{label} ({where})", f"{state}, not translated")
                continue
            for name in names:
                if name not in value:
                    fail(f"{table}: {key!r} {language}{label} ({where})", f"{name!r} is never translated")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--derived", required=True, type=Path, help="the -derivedDataPath of an internal build")
    ap.add_argument("--base", required=True, help="build 23's commit, d387a64, whose Localizable keys the app keeps")
    ap.add_argument("--enforce", action="store_true", help="also fail on keys of the Lite tables no source uses")
    args = ap.parse_args()

    base = subprocess.run(["git", "show", f"{args.base}:ios/DyorHQ/Resources/Localizable.xcstrings"], cwd=IOS,
                          capture_output=True)
    if base.returncode:
        stop(f"no ios/DyorHQ/Resources/Localizable.xcstrings at {args.base}")
    try:
        base_keys = set(json.loads(base.stdout).get("strings") or {})
    except ValueError:
        stop(f"the Localizable.xcstrings at {args.base} is not a readable String Catalog")
    if not args.derived.is_dir():
        stop(f"no {args.derived}: build DyorHQInternal.xcodeproj with -derivedDataPath {args.derived} first")
    shipped = shipped_languages()
    used = used_keys(args.derived.resolve())

    for table, keys in sorted(used.items()):
        if table == DEFAULT_TABLE:
            for key, where in sorted(keys.items()):
                if key not in base_keys:
                    fail(f"{where}: {key!r}", "not a key of build 23's Localizable: name its table (Stellar…)")
        elif LITE_TABLE.fullmatch(table):
            path = TABLES / f"{table}.xcstrings"
            if not path.is_file():
                fail(f"{table} ({', '.join(sorted(set(keys.values())))})", f"no {path.relative_to(IOS.parent)}")
                continue
            catalog = load_catalog(path)
            for key, where in sorted(keys.items()):
                if key not in catalog:
                    fail(f"{table}: {key!r} ({where})", f"missing from {path.name}: sync the table")
                else:
                    check_lite_key(table, key, catalog[key], where, shipped)
        else:
            fail(f"{table} ({', '.join(sorted(set(keys.values())))})",
                 "an unknown table: Lite text is in Lite or Stellar<Area>, reused text in Localizable")

    tables = sorted(path for path in TABLES.glob("*.xcstrings") if LITE_TABLE.fullmatch(path.stem))
    for path in tables:
        for key in sorted(set(load_catalog(path)) - set(used.get(path.stem, {}))):
            unused.append(f"{path.stem}: {key!r}: the Lite code doesn't use it")

    for finding in findings:
        print(f"check-lite-strings: {finding}")
    for key in unused:
        print(f"check-lite-strings: {key}{'' if args.enforce else ' (fails with --enforce)'}")
    failed = len(findings) + (len(unused) if args.enforce else 0)
    print(f"check-lite-strings: {sum(len(keys) for keys in used.values())} keys in {len(used)} tables, "
          f"{len(tables)} Lite tables, languages {', '.join(shipped)}: {len(findings)} finding"
          f"{'s' if len(findings) != 1 else ''}, {len(unused)} unused key{'s' if len(unused) != 1 else ''} "
          f"({'enforce' if args.enforce else 'warn'} mode)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
