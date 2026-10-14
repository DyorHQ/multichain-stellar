#!/usr/bin/env python3
"""Merges checked translations into the String Catalogs (the app's Localizable and InfoPlist, DyorKit's Localizable), so
the catalogs are never edited by hand. Re-runnable: every run sets each translated language of every key from the
inputs, and a second run changes nothing.

    scripts/dev/merge-translations.py <folder>                # check everything, then write the catalogs
    scripts/dev/merge-translations.py <folder> --check        # write nothing; exit 1 when a catalog differs from the merge
    scripts/dev/merge-translations.py <folder> --drop-stale   # also remove the keys the last sync marked stale

<folder> holds one file per language, <language>.json: {"app": {…}, "kit": {…}, "infoplist": {…}}, each mapping a
catalog key to {"value": "…"} or {"plural": {"one": "…", "other": "…"}}. An optional <folder>/merge-overlay.json,
{"<language>": {"app": {…}, …}}, holds entries written or corrected after those files were checked; it wins over them.

Every key a catalog asks to translate (not marked never to translate, not stale) needs a translation in every language,
with the English's format specifiers (the same positions and types, positional when there are two or more), exactly the
plural categories Xcode keeps for the language when the English or the translation varies by plural, a non-empty text,
the names that are never translated, and the English's leading and trailing whitespace. Any problem refuses the whole
merge: nothing is written. The catalogs are written as Xcode writes them (scripts/dev/strings-sync.sh's sync output), so
Xcode and the sync leave them as they are. Prints keys and counts, never a translation. Afterwards run
scripts/dev/check-strings.py --enforce.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
CATALOGS = {
    "app": "ios/DyorHQ/Resources/Localizable.xcstrings",
    "kit": "ios/DyorKit/Sources/DyorKit/Resources/Localizable.xcstrings",
    "infoplist": "ios/DyorHQ/Resources/InfoPlist.xcstrings",
}
SOURCE = "en"
# The plural categories Xcode keeps for each language (XCStringsParser.framework's variationConfigFile.plist,
# ComplementedPluralKeys): no "many" for es or fr, whatever CLDR adds for a million; zh-Hans and ko have "other" only.
PLURALS = {"es": ["one", "other"], "fr": ["one", "other"], "zh-Hans": ["other"], "ko": ["other"]}
LANGUAGES = list(PLURALS)
OVERLAY = "merge-overlay.json"
NEVER_TRANSLATED = ["DyorHQ", "Face ID", "Touch ID", "Optic ID"]
# As check-strings.py reads them: %% is a percent sign, and a percent sign before a space is text ("1% slippage").
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])")


def specifiers(text):
    """The format specifiers of `text` as (position, type), positions counted when none is written, or None when the
    text mixes positional and unpositioned specifiers."""
    found = [(int(m.group(1)) if m.group(1) else None, (m.group(2) or "") + m.group(3))
             for m in SPECIFIER.finditer(text.replace("%%", ""))]
    if all(position is None for position, _ in found):
        return [(index + 1, kind) for index, (_, kind) in enumerate(found)], False
    if any(position is None for position, _ in found):
        return None, True
    return found, True


def english_forms(key, entry):
    """The English of a catalog entry: {"": text}, or its plural forms by category."""
    english = (entry.get("localizations") or {}).get(SOURCE)
    if not english:
        return {"": key}
    if set(english) == {"stringUnit"}:
        return {"": english["stringUnit"]["value"]}
    plural = (english.get("variations") or {}).get("plural")
    if set(english) == {"variations"} and set(english["variations"]) == {"plural"} and plural:
        return {category: form["stringUnit"]["value"] for category, form in plural.items()}
    return None


def translation_problems(language, english, translation):
    """What is wrong with one language's translation of one key, as short reasons; none when it can be written."""
    if not isinstance(translation, dict) or len(translation) != 1 or not ({"value", "plural"} & set(translation)):
        return ['not {"value": …} or {"plural": {…}}']
    reference = english.get("other", english.get(""))
    expected, _ = specifiers(reference)
    if expected is None:
        return ["the English mixes positional and unpositioned specifiers"]
    if "plural" in translation:
        forms = translation["plural"]
        if not isinstance(forms, dict) or sorted(forms) != sorted(PLURALS[language]):
            return [f"plural categories {sorted(forms) if isinstance(forms, dict) else forms} are not {PLURALS[language]}"]
    elif "" not in english:
        return ["the English varies by plural: give the plural forms"]
    else:
        forms = {"": translation["value"]}
    problems = []
    for category, text in forms.items():
        label = f" [{category}]" if category else ""
        if not isinstance(text, str) or not text.strip():
            problems.append(f"empty{label}")
            continue
        found, positional = specifiers(text)
        if found is None:
            problems.append(f"mixes positional and unpositioned specifiers{label}")
        elif sorted(set(found)) != sorted(set(expected)):
            problems.append(f"specifiers {sorted(set(found))} are not the English's {sorted(set(expected))}{label}")
        elif len(found) >= 2 and not positional:
            problems.append(f"two or more specifiers need positions (%1$@, %2$lld){label}")
        for name in NEVER_TRANSLATED:
            if name in reference and name not in text:
                problems.append(f"{name!r} is never translated{label}")
        if (text[:1].isspace(), text[-1:].isspace()) != (reference[:1].isspace(), reference[-1:].isspace()):
            problems.append(f"leading or trailing whitespace differs from the English{label}")
    return problems


def localization(translation):
    """A catalog localization, as Xcode writes a translated one."""
    def unit(text):
        return {"stringUnit": {"state": "translated", "value": text}}
    if "plural" in translation:
        return {"variations": {"plural": {category: unit(text) for category, text in translation["plural"].items()}}}
    return unit(translation["value"])


def xcode_json(catalog, trailing_newline):
    """`catalog` as Xcode writes a .xcstrings file: sorted keys, two-space indent, " : " between a key and its value, an
    empty object as "{", a blank line and "}"."""
    text = json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False, sort_keys=True)
    lines = []
    for line in text.split("\n"):
        empty = re.match(r"^( *)(.*)\{\}(,?)$", line)
        if empty:
            lines += [f"{empty.group(1)}{empty.group(2)}{{", "", f"{empty.group(1)}}}{empty.group(3)}"]
        else:
            lines.append(line)
    return "\n".join(lines) + ("\n" if trailing_newline else "")


def load(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"merge-translations: cannot read {path}: {error}", file=sys.stderr)
        sys.exit(2)


def main():
    parser = argparse.ArgumentParser(description="Merge checked translations into the String Catalogs.")
    parser.add_argument("folder", type=Path, help="the folder with <language>.json and an optional merge-overlay.json")
    parser.add_argument("--check", action="store_true", help="write nothing; exit 1 when a catalog differs from the merge")
    parser.add_argument("--drop-stale", action="store_true", help="remove the keys the last sync marked stale")
    args = parser.parse_args()

    inputs = {language: load(args.folder / f"{language}.json") for language in LANGUAGES}
    overlay_path = args.folder / OVERLAY
    overlay = load(overlay_path) if overlay_path.exists() else {}
    problems = [f"{OVERLAY}: {language!r} is not one of {LANGUAGES}" for language in overlay if language not in PLURALS]
    for language, files in [(language, inputs[language]) for language in LANGUAGES] + list(overlay.items()):
        problems += [f"{language}: unknown catalog {name!r}" for name in files if name not in CATALOGS]

    used = set()
    results = []
    for name, relative in CATALOGS.items():
        path = ROOT / relative
        raw = path.read_text(encoding="utf-8")
        catalog = json.loads(raw)
        if catalog.get("sourceLanguage") != SOURCE:
            problems.append(f"{relative}: sourceLanguage is not {SOURCE!r}")
        strings = catalog.get("strings") or {}
        counts = {"keys": 0, "plural": 0, "never": 0, "stale": 0, "dropped": 0}
        for key in sorted(strings):
            entry = strings[key]
            if entry.get("extractionState") == "stale":
                counts["stale"] += 1
                if args.drop_stale:
                    del strings[key]
                    counts["dropped"] += 1
                    print(f"merge-translations: {relative}: dropped the stale key {key!r}")
                continue
            if entry.get("shouldTranslate") is False:
                counts["never"] += 1
                continue
            english = english_forms(key, entry)
            if english is None:
                problems.append(f"{relative}: {key!r}: the English is neither a string nor whole-string plural forms")
                continue
            counts["keys"] += 1
            counts["plural"] += "" not in english
            localizations = entry.setdefault("localizations", {})
            for language in LANGUAGES:
                translation = (overlay.get(language) or {}).get(name, {}).get(key)
                if translation is not None:
                    used.add((language, name, key, True))
                else:
                    translation = inputs[language].get(name, {}).get(key)
                    used.add((language, name, key, False))
                if translation is None:
                    problems.append(f"{relative}: {key!r}: no {language} translation")
                    continue
                found = translation_problems(language, english, translation)
                problems += [f"{relative}: {key!r} {language}: {problem}" for problem in found]
                if not found:
                    localizations[language] = localization(translation)
        results.append((name, relative, path, raw, xcode_json(catalog, raw.endswith("\n")), counts))

    for language, files in overlay.items():
        for name, entries in files.items():
            for key in entries:
                if (language, name, key, True) not in used:
                    problems.append(f"{OVERLAY}: {language} {name} {key!r} is not a key to translate in the catalog")
    unused = sorted({(name, key) for language in LANGUAGES for name, entries in inputs[language].items() for key in entries
                     if (language, name, key, False) not in used and (language, name, key, True) not in used})
    for name, key in unused:
        print(f"merge-translations: left out (no longer in the {name} catalog): {key!r}")

    if problems:
        for problem in problems:
            print(f"merge-translations: {problem}")
        sys.stdout.flush()
        print(f"merge-translations: refusing to write: {len(problems)} problem{'s' if len(problems) != 1 else ''}", file=sys.stderr)
        return 1

    differs = False
    for name, relative, path, raw, merged, counts in results:
        changed = merged != raw
        differs |= changed
        if changed and not args.check:
            path.write_text(merged, encoding="utf-8")
        state = ("differs from the merge" if args.check else "written") if changed else "up to date"
        print(f"merge-translations: {relative}: {counts['keys']} keys in {', '.join(LANGUAGES)} ({counts['plural']} with "
              f"plural forms), {counts['never']} never translated, {counts['stale']} stale"
              f"{' (dropped)' if args.drop_stale and counts['stale'] else ''}: {state}")
    return 1 if args.check and differs else 0


if __name__ == "__main__":
    sys.exit(main())
