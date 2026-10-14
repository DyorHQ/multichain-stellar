#!/usr/bin/env python3
"""Lists the Stellar copies of Monad code whose source has changed since they were copied.

A Monad piece that is private or EVM-typed is copied into ios/DyorHQ/Lite with a Stellar name, and the copy starts with
a header naming its source declaration and that declaration's hash at the base:
    // Stellar copy of ios/DyorHQ/Home/HomeView.swift HomeAction (42cd8c7 sha256:<first 12 hex>)
This script finds every such header under app/ios/DyorHQ/Lite, finds the declaration in the base's file, brace-matched
from its declaration line, and compares the hash. A mismatch names the copy to re-sync with its source. The base is the
app copy's upstream snapshot, as for check-build23.py: the latest "Squashed 'app/' …" commit, whose tree is the public
app at its root, so a header's path is the app's own (ios/…).

From app/ios/, with Python's isolated mode:
    python3 -I Internal/check-copies.py                   # check every copy against the snapshot
    python3 -I Internal/check-copies.py --header ios/DyorHQ/Home/HomeView.swift HomeAction
                                                          # print the header for a new copy
    python3 -I Internal/check-copies.py --base <rev>      # against another snapshot of the public app

The symbol is a declaration's name (a type, func, var or let). When the name is declared more than once in the file,
qualify it with its enclosing type: HomeView.heroCard. The hash covers the declaration's lines, from the one with its
keyword through the one with its closing brace (attributes and doc comments on the lines above are not part of it).

Prints paths, symbols and hashes, never a file's contents. Exits 0 when every copy matches (or there are none), 1 on
any finding, 2 when it can't run.
"""
import argparse
import hashlib
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
LITE = IOS / "DyorHQ" / "Lite"
HEADER = re.compile(r"\s*// Stellar copy of (\S+) (\S+) \(([0-9a-f]{7,40}) sha256:([0-9a-f]{12})\)\s*")
MODIFIER = (r"(?:public|private|fileprivate|internal|package|open|final|static|class|override|mutating|nonmutating|lazy"
            r"|weak|unowned|nonisolated|indirect|convenience|required|dynamic|optional)(?:\([\w ]*\))?")
DECLARATION = re.compile(r"^[ \t]*(?:@[\w.]+(?:\([^)\n]*\))?[ \t]+)*(?:" + MODIFIER + r"[ \t]+)*"
                         r"(?P<kind>struct|class|enum|actor|protocol|extension|func|var|let|typealias)[ \t]+"
                         r"(?P<name>[\w.]+)", re.M)
# What may end a line in the middle of a declaration's signature, or start the line that carries it on. Not "?": a line
# that ends with an optional type (`var presented: PresentedScreen?`) is a whole declaration.
CONTINUES_LINE = tuple(",:=&|.<(")
CONTINUATION = re.compile(r"\s*(\{|where\b|->|throws\b|rethrows\b|async\b|:|=|\.|&&|\|\|)")

findings = []


def fail(where, message):
    findings.append(f"{where}: {message}")


def stop(message):
    print(f"check-copies: {message}", file=sys.stderr)
    sys.exit(2)


def git(*args):
    result = subprocess.run(["git", *args], cwd=IOS, capture_output=True)
    return result.stdout if result.returncode == 0 else None


def check_build23():
    """check-build23.py as a module: the base resolution and the repository's layout are its."""
    spec = importlib.util.spec_from_file_location("check_build23", Path(__file__).with_name("check-build23.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build23 = check_build23()


# Reading Swift

def skip_string(text, i):
    """The index just past the string literal starting at `i` (raw, multi-line and interpolated ones too)."""
    n = len(text)
    hashes = 0
    while text[i] == "#":
        hashes += 1
        i += 1
    quote = '"""' if text.startswith('"""', i) else '"'
    i += len(quote)
    close, escape = quote + "#" * hashes, "\\" + "#" * hashes
    while i < n:
        if text.startswith(escape, i):
            i += len(escape)
            if i < n and text[i] == "(":
                i = skip_interpolation(text, i)
            else:
                i += 1
        elif text.startswith(close, i):
            return i + len(close)
        elif len(quote) == 1 and text[i] == "\n":
            return i
        else:
            i += 1
    return n


def skip_interpolation(text, i):
    """The index just past the interpolation's parenthesis that opens at `i`."""
    depth = 0
    while i < len(text):
        if text[i] == '"' or re.match(r'#+"', text[i:i + 8]):
            i = skip_string(text, i)
            continue
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def skip_block_comment(text, i):
    depth = 0
    while i < len(text):
        if text.startswith("/*", i):
            depth += 1
            i += 2
        elif text.startswith("*/", i):
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return i


def code_only(text):
    """`text` with its comments and string literals blanked (newlines kept), so braces and names are code."""
    out = list(text)
    i = 0
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
        elif text.startswith("/*", i):
            end = skip_block_comment(text, i)
        elif text[i] == '"' or (text[i] == "#" and re.match(r'#+"', text[i:i + 8])):
            end = skip_string(text, i)
        else:
            i += 1
            continue
        for k in range(i, end):
            if out[k] != "\n":
                out[k] = " "
        i = end
    return "".join(out)


def declaration_end(code, start):
    """The index of the last character of the declaration whose keyword line starts at `start`: its closing brace, or
    the end of its last line when it has no body."""
    depth, i = 0, start
    while i < len(code):
        c = code[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "{" and depth == 0:
            return matching_brace(code, i)
        elif c == "\n" and depth == 0:
            line = code[code.rfind("\n", 0, i) + 1:i].rstrip()
            following = code[i + 1:].lstrip("\n")
            if not line.endswith(CONTINUES_LINE) and not CONTINUATION.match(following):
                return i - 1
        i += 1
    return len(code) - 1


def matching_brace(code, i):
    depth = 0
    for k in range(i, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(code) - 1


def find_declaration(code, symbol):
    """(start, end) of `symbol`'s declaration in the code, its enclosing types first when it is qualified (A.b), or a
    reason it can't be found."""
    start, end = 0, len(code)
    for name in symbol.split("."):
        found = []
        for match in DECLARATION.finditer(code, start, end):
            if match.group("name") == name:
                depth = code.count("{", start, match.start()) - code.count("}", start, match.start())
                found.append((match.group("kind") == "extension", depth, match.start()))
        if not found:
            return None, f"no declaration {name}"
        if any(not is_extension for is_extension, _, _ in found):
            found = [entry for entry in found if not entry[0]]
        shallowest = min(depth for _, depth, _ in found)
        found = [entry for entry in found if entry[1] == shallowest]
        if len(found) > 1:
            return None, f"{name} is declared {len(found)} times: qualify it with its enclosing type (Type.{name})"
        start = found[0][2]
        end = declaration_end(code, start) + 1
    return (start, end), None


def declaration_hash(text, symbol):
    """The first 12 hex of the declaration's SHA-256 (its whole lines), or None and the reason."""
    span, reason = find_declaration(code_only(text), symbol)
    if span is None:
        return None, reason
    start, end = span
    line_end = text.find("\n", end)
    lines = text[start:len(text) if line_end < 0 else line_end]
    return hashlib.sha256(lines.encode("utf-8", errors="surrogateescape")).hexdigest()[:12], None


def base_text(base, path):
    data = git("cat-file", "blob", f"{base}:{path}")
    return None if data is None else data.decode("utf-8", errors="surrogateescape")


# Checking

def check(base):
    copies = 0
    for file in sorted(LITE.rglob("*.swift")) if LITE.is_dir() else []:
        where = file.relative_to(build23.ROOT)
        for number, line in enumerate(file.read_text(encoding="utf-8", errors="replace").split("\n"), 1):
            if "Stellar copy of" not in line or not line.lstrip().startswith("//"):
                continue
            header = HEADER.fullmatch(line)
            if not header:
                fail(f"{where}:{number}",
                     "a copy header is `// Stellar copy of <path> <symbol> (<base> sha256:<12 hex>)`")
                continue
            copies += 1
            path, symbol, rev, expected = header.groups()
            text = base_text(base, path)
            if text is None:
                fail(f"{where}:{number}", f"no {path} in the base")
                continue
            actual, reason = declaration_hash(text, symbol)
            if actual is None:
                fail(f"{where}:{number}", f"{reason} in the base's {path}")
            elif actual != expected:
                fail(f"{where}:{number}", f"{path} {symbol} hashes to {actual} at the base, not {expected} (copied at "
                                          f"{rev}): re-sync the copy with it, then update the header")
    return copies


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="the snapshot the copies are checked against (default: the latest \"Squashed "
                                   f"'{build23.PREFIX}/' …\" commit, as for check-build23.py)")
    ap.add_argument("--header", nargs=2, metavar=("PATH", "SYMBOL"), help="print the header for a copy of SYMBOL in "
                    "PATH (the app's own path, ios/…)")
    args = ap.parse_args()

    try:
        _, base = build23.resolve_base(args.base)
    except LookupError as error:
        stop(str(error))

    if args.header:
        path, symbol = args.header
        text = base_text(base, path)
        if text is None:
            stop(f"no {path} at {base}")
        digest, reason = declaration_hash(text, symbol)
        if digest is None:
            stop(f"{reason} in {path} at {base}")
        print(f"// Stellar copy of {path} {symbol} ({base} sha256:{digest})")
        return 0

    copies = check(base)
    for finding in findings:
        print(f"check-copies: {finding}")
    lite = LITE.relative_to(build23.ROOT)
    if copies == 0 and not findings:
        print(f"check-copies: no copies under {lite}")
        return 0
    print(f"check-copies: {copies} cop{'ies' if copies != 1 else 'y'} under {lite} against the snapshot {base}: "
          f"{len(findings)} finding{'s' if len(findings) != 1 else ''}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
