#!/usr/bin/env python3
"""Lints the String Catalogs and the code that feeds them. WARN mode for now: it prints what it finds and exits 0;
--enforce exits 1 on any finding (from the string conversion, L2, on).

    scripts/dev/check-strings.py            # warn
    scripts/dev/check-strings.py --enforce  # fail on any finding

Catalogs: every tracked ios/**/*.xcstrings (the app's Localizable and InfoPlist, DyorKit's Localizable). Checks:
  1. A catalog carries only languages the app ships (CFBundleLocalizations in ios/project.yml): any other language
     would be built into the app and offered half-translated.
  2. Every shipped language other than English has every string translated (not new, not needing review, not empty),
     except strings marked stale or never to translate.
  3. Placeholders: each translation and plural variant has the same format specifiers as the English, and positional
     ones (%1$@) when it has two or more.
  4. Names that are never translated (DyorHQ, Face ID, Touch ID, Optic ID) stay as they are.
  5. No leading or trailing whitespace that the English doesn't have.
Code (ios/DyorHQ and ios/DyorKit/Sources): no String(localized:…, locale:), whose locale never selects the language
(use tr() or L10n.tr), and no NSLocalizedString. Prints keys and file names, never anything secret: catalogs hold UI text
only.
"""
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
SOURCE = "en"
NEVER_TRANSLATED = ["DyorHQ", "Face ID", "Touch ID", "Optic ID"]
# A percent sign before a space is text ("1% slippage", "80% and 90%", "1 % de"), not a specifier with printf's space
# flag, which no string of the app uses: read as one, every translation of such a string would differ from the English.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])")

findings = []


def warn(where, message):
    findings.append(f"{where}: {message}")


def shipped_languages():
    project = (ROOT / "ios" / "project.yml").read_text(encoding="utf-8")
    match = re.search(r"^\s*CFBundleLocalizations:\s*\[([^\]]*)\]", project, re.M)
    if not match:
        warn("ios/project.yml", "no CFBundleLocalizations: the shipped languages are unknown")
        return [SOURCE]
    return [code.strip().strip("'\"") for code in match.group(1).split(",") if code.strip()]


def specifiers(text):
    """The format specifiers in `text`, as (position or None, kind), with %% skipped."""
    found = []
    for m in SPECIFIER.finditer(text.replace("%%", "")):
        kind = m.group(3)
        kind = "int" if kind in "dDiuUxXoOc" else "float" if kind in "fFeEgGaA" else "object" if kind in "@sSp" else kind
        found.append((int(m.group(1)) if m.group(1) else None, kind))
    return found


def units(localization):
    """Every (label, stringUnit) of one language's entry: the plain one and each plural or device variation."""
    out = []
    if "stringUnit" in localization:
        out.append(("", localization["stringUnit"]))
    for axis, cases in (localization.get("variations") or {}).items():
        for case, value in cases.items():
            out.extend((f" [{axis}={case}{label}]", unit) for label, unit in units(value))
    return out


def check_catalog(path, shipped):
    rel = path.relative_to(ROOT)
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"check-strings: {rel} is not a readable catalog: {error}", file=sys.stderr)
        sys.exit(2)
    if catalog.get("sourceLanguage") != SOURCE:
        warn(rel, f"sourceLanguage is {catalog.get('sourceLanguage')!r}, not {SOURCE!r}")
    for key, entry in sorted((catalog.get("strings") or {}).items()):
        where = f"{rel}: {key!r}"
        localizations = entry.get("localizations") or {}
        for language in sorted(set(localizations) - set(shipped)):
            warn(where, f"has {language}, which the app doesn't ship (add it to CFBundleLocalizations only when complete)")
        if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
            continue
        english = [unit.get("value", "") for _, unit in units(localizations.get(SOURCE, {}))] or [key]
        source = english[-1]
        source_kinds = Counter(kind for _, kind in specifiers(source))
        for language in shipped:
            if language == SOURCE:
                continue
            found = units(localizations.get(language, {}))
            if not found:
                warn(where, f"no {language} translation")
                continue
            for label, unit in found:
                value = unit.get("value", "")
                spot = f"{where} {language}{label}"
                if unit.get("state") != "translated" or not value.strip():
                    warn(spot, f"state is {unit.get('state')!r}, not translated")
                    continue
                specs = specifiers(value)
                if Counter(kind for _, kind in specs) != source_kinds and not label.startswith(" [plural="):
                    warn(spot, "placeholders differ from the English")
                if len(specs) >= 2 and any(position is None for position, _ in specs):
                    warn(spot, "two or more placeholders need positions (%1$@, %2$lld)")
                for name in NEVER_TRANSLATED:
                    if name in source and name not in value:
                        warn(spot, f"{name!r} is never translated")
                if (value[:1].isspace(), value[-1:].isspace()) != (source[:1].isspace(), source[-1:].isspace()):
                    warn(spot, "leading or trailing whitespace differs from the English")


def check_code():
    files = subprocess.run(["git", "ls-files", "ios/DyorHQ/*.swift", "ios/DyorKit/Sources/*.swift"],
                           cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    for name in files:
        for number, line in enumerate((ROOT / name).read_text(encoding="utf-8").splitlines(), 1):
            code = line.strip()
            if code.startswith("//"):
                continue
            if "String(localized:" in code and "locale:" in code:
                warn(f"{name}:{number}", "String(localized:…, locale:) never selects the language; use tr() or L10n.tr")
            if "NSLocalizedString(" in code:
                warn(f"{name}:{number}", "NSLocalizedString; use a SwiftUI literal, tr() or L10n.tr")


def main():
    enforce = "--enforce" in sys.argv[1:]
    unknown = [arg for arg in sys.argv[1:] if arg != "--enforce"]
    if unknown:
        print(f"check-strings: unknown argument: {unknown[0]}", file=sys.stderr)
        return 2
    shipped = shipped_languages()
    catalogs = subprocess.run(["git", "ls-files", "ios/*.xcstrings"], cwd=ROOT, capture_output=True, text=True,
                              check=True).stdout.split()
    if not catalogs:
        warn("ios", "no tracked .xcstrings catalog")
    for name in catalogs:
        check_catalog(ROOT / name, shipped)
    check_code()
    for finding in findings:
        print(f"check-strings: {finding}")
    mode = "enforce" if enforce else "warn"
    print(f"check-strings: {len(catalogs)} catalogs, shipped languages {', '.join(shipped)}: "
          f"{len(findings)} finding{'s' if len(findings) != 1 else ''} ({mode} mode)")
    return 1 if enforce and findings else 0


if __name__ == "__main__":
    sys.exit(main())
