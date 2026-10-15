#!/usr/bin/env python3
"""Checks that the App Store build is still the public app's: the internal (Stellar) work changes nothing it compiles.

This repository holds a copy of the public DyorHQ app under app/, a git subtree. Its upstream snapshot is the latest
"Squashed 'app/' …" commit in HEAD's history (git subtree add or pull --squash writes it), whose tree is the public app
at its root: build 23 with its build number and tagline since. The check compares app/ with that snapshot.

From app/ios/, with Python's isolated mode:
    python3 -I Internal/check-build23.py                # the commits since the snapshot (snapshot..HEAD, under app/)
    python3 -I Internal/check-build23.py --worktree     # the working tree, untracked files included
    python3 -I Internal/check-build23.py --app <App Store build>/Release-iphonesimulator/DyorHQ.app
    python3 -I Internal/check-build23.py --base <rev>   # another snapshot of the public app (the app at its root)

It checks every path of app/ that differs from the snapshot (the paths below are app/'s own):
    ios/DyorKit/**                          never changes (Package.resolved included)
    ios/Internal/**                         anything: the internal project only
    added ios/DyorHQ/Lite/**.swift          wholly inside #if STELLAR_LITE: outside it, blank lines and // comments only
    any other added ios/DyorHQ/Lite/**      fails: it would ship in the App Store app (resources go in ios/Internal)
    any other added .swift                  fails, as does a deleted or renamed app file (ios/DyorHQ/**)
    a nested repository (gitlink)           fails, wherever it is
    ios/project.yml, ios/DyorHQ/Info.plist  only the CFBundleVersion line
    ios/.gitignore                          only added project-internal.json and DerivedData* lines (and comments)
    modified ios/DyorHQ/**.swift            with its #if STELLAR_LITE blocks stripped, byte for byte the snapshot's file
    anything else                           listed in Internal/unflagged-changes.txt with a reason, and within its rule
An entry in unflagged-changes.txt never widens the rules above it: the strict paths can't be listed, `any` is refused
for a Swift file and under ios/DyorHQ, and only a modified app Swift file's stripped text may take a `literal` entry.
Stripping keeps a stack of #if frames: `#if STELLAR_LITE` drops its lines, its `#else` keeps the rest, `#endif`
closes it and the three directive lines go. Every other #if is kept as written. `#elseif` in a STELLAR_LITE frame, and
any other condition naming STELLAR_LITE (`#if !STELLAR_LITE`, `#if STELLAR_LITE && DEBUG`), fail as unsupported.

--app also looks inside a built App Store app: no symbol of DyorLite, StellarKit, StellarCore or LiteClient in any of
its binaries (nm -U), no bundle or framework of theirs, no Lite or Stellar* string table and nothing else from
Internal/Resources.

Prints paths and line numbers, never a file's contents. Exits 0 when clean, 1 on any finding, 2 when it can't run.
check-lite-strings.py and check-copies.py take their default base from this script (resolve_base).
"""
import argparse
import difflib
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
UNFLAGGED = IOS / "Internal" / "unflagged-changes.txt"
# Symbols of the Lite packages, as they appear in nm's (mangled) names.
LITE_SYMBOL = re.compile(r"DyorLite|StellarCore|LiteClient|StellarKit")
# A bundle, framework or library of a Lite package (SwiftPM names resource bundles <Package>_<Target>.bundle).
LITE_PRODUCT = re.compile(r"(DyorLite|StellarCore|LiteClient|StellarKit)[._]")
# The Lite string tables, as catalogs or compiled into an .lproj.
LITE_TABLE = re.compile(r"(Lite|Stellar.*)\.(xcstrings|strings|stringsdict)")
DIRECTIVE = re.compile(r"\s*#(if|elseif|else|endif)\b(.*)")
MACH_O = {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
          b"\xbe\xba\xfe\xca"}
# Paths whose own rule is the only one: unflagged-changes.txt can't list them.
VERSION_ONLY = ("ios/project.yml", "ios/DyorHQ/Info.plist")
GITIGNORE = "ios/.gitignore"

findings = []


def fail(where, message):
    findings.append(f"{where}: {message}")


def stop(message):
    print(f"check-build23: {message}", file=sys.stderr)
    sys.exit(2)


def run_git(*args, cwd=IOS):
    """git's output, or None when it fails."""
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True)
    return result.stdout if result.returncode == 0 else None


def git(*args):
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True)
    if result.returncode:
        reason = result.stderr.decode(errors="replace").strip().splitlines()
        stop(f"git {args[0]} failed: {reason[-1] if reason else result.returncode}")
    return result.stdout


def repository_root():
    found = run_git("rev-parse", "--show-toplevel")
    if found is None:
        stop(f"{IOS} is not in a git checkout")
    return Path(found.decode().strip())


ROOT = repository_root()
# Where the app copy sits in this repository: "app" ("" if the app were at the root).
PREFIX = "" if IOS.parent == ROOT else IOS.parent.relative_to(ROOT).as_posix()


def shown(path):
    """An app path (ios/…) as this repository names it (app/ios/…): what the checks print."""
    return f"{PREFIX}/{path}" if PREFIX else path


# The base: the app copy's upstream snapshot

def resolve_base(rev=None):
    """(full hash, short hash) of the base the app copy is compared with: `rev`, or by default the latest commit in
    HEAD's history whose subject is git subtree's "Squashed '<prefix>/' content from commit …" (add) or "Squashed
    '<prefix>/' changes from …" (pull). Its tree is the public app at its root. Raises LookupError with the reason."""
    if rev is None:
        if not PREFIX:
            raise LookupError("the app is at this repository's root, so there is no subtree snapshot: pass --base")
        subject = re.compile(rf"Squashed '{re.escape(PREFIX)}/' (content from commit|changes from) \S+")
        out = run_git("log", "--format=%H %s", f"--grep=^Squashed '{PREFIX}/' ", "HEAD")
        found = [line.split(" ", 1)[0] for line in (out or b"").decode(errors="replace").splitlines()
                 if subject.fullmatch(line.partition(" ")[2])]
        if not found:
            raise LookupError(f"no \"Squashed '{PREFIX}/' …\" commit in HEAD's history (a shallow clone has none: "
                              "fetch the whole history), or pass --base")
        rev = found[0]
    full = run_git("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}")
    if full is None:
        raise LookupError(f"no commit {rev} in this repository")
    full = full.decode().strip()
    if run_git("cat-file", "-e", f"{full}:ios/DyorHQ") is None:
        raise LookupError(f"{rev} has no ios/DyorHQ at its root: it isn't a snapshot of the public app")
    return full, run_git("rev-parse", "--short", full).decode().strip()


# Stripping

class Unsupported(Exception):
    def __init__(self, line, message):
        super().__init__(message)
        self.line = line


def strip(text):
    """The lines of `text` the App Store build compiles, with their line numbers in `text`: every #if STELLAR_LITE
    block's lines dropped and its #else kept, the other #if blocks as written."""
    kept, numbers = [], []
    frames = []  # [is STELLAR_LITE, dropped, has had its #else, line of its #if]
    for number, line in enumerate(text.split("\n"), 1):
        directive = DIRECTIVE.match(line)
        if directive:
            word, condition = directive.group(1), directive.group(2).split("//")[0].strip()
            names_lite = re.search(r"\bSTELLAR_LITE\b", condition) is not None
            if word in ("if", "elseif") and names_lite and (word == "elseif" or condition != "STELLAR_LITE"):
                raise Unsupported(number, f"#{word} {condition}: only `#if STELLAR_LITE` (and its #else) is supported")
            if word != "if" and not frames:
                raise Unsupported(number, f"#{word} without an #if")
            if word == "if":
                frames.append([condition == "STELLAR_LITE", condition == "STELLAR_LITE", False, number])
                if frames[-1][0]:
                    continue
            elif frames[-1][0]:
                if word == "elseif":
                    raise Unsupported(number, "#elseif in a #if STELLAR_LITE block is unsupported")
                if word == "endif":
                    frames.pop()
                elif frames[-1][2]:
                    raise Unsupported(number, "a second #else in a #if STELLAR_LITE block")
                else:
                    frames[-1][1:3] = [False, True]
                continue
            elif word == "endif":
                frames.pop()
                if any(frame[1] for frame in frames):
                    continue
        if not any(frame[1] for frame in frames):
            kept.append(line)
            numbers.append(number)
    if frames:
        raise Unsupported(frames[-1][3], "#if without an #endif")
    return kept, numbers


def first_difference(ours, theirs):
    """The index of the first line where two lists of lines differ, or None when they are equal."""
    for index, (a, b) in enumerate(zip(ours, theirs)):
        if a != b:
            return index
    return None if len(ours) == len(theirs) else min(len(ours), len(theirs))


def stripped(where, new):
    """`new`'s stripped lines and their line numbers, or None after a finding."""
    try:
        return strip(new)
    except Unsupported as error:
        fail(f"{where}:{error.line}", str(error))
        return None


def line_of(numbers, index):
    """The line, in the file before stripping, of the stripped line at `index` (one past the end for a missing one)."""
    if index < len(numbers):
        return numbers[index]
    return numbers[-1] + 1 if numbers else 1


# The rules

def check_lite_file(where, new):
    result = stripped(where, new)
    if result is None:
        return
    for line, number in zip(*result):
        code = line.strip()
        if code and not code.startswith("//"):
            fail(f"{where}:{number}", "code outside #if STELLAR_LITE: a new file in Lite/ is wholly inside it")
            return


def check_app_swift(where, old, new):
    result = stripped(where, new)
    if result is None:
        return
    kept, numbers = result
    index = first_difference(kept, old.split("\n"))
    if index is not None:
        fail(f"{where}:{line_of(numbers, index)}",
             f"differs from the snapshot outside #if STELLAR_LITE (snapshot line {index + 1})")


def is_version_line(path, lines, index):
    if path == "ios/project.yml":
        return re.fullmatch(r'\s*CFBundleVersion:\s*"?\d+"?\s*', lines[index]) is not None
    return (index > 0 and re.fullmatch(r"\s*<key>CFBundleVersion</key>\s*", lines[index - 1]) is not None
            and re.fullmatch(r"\s*<string>\d+</string>\s*", lines[index]) is not None)


def check_version_only(path, old, new):
    where = shown(path)
    old_lines, new_lines = old.split("\n"), new.split("\n")
    if len(old_lines) != len(new_lines):
        fail(f"{where}:{first_difference(new_lines, old_lines) + 1}", "only the CFBundleVersion line may change")
        return
    for index, (a, b) in enumerate(zip(old_lines, new_lines)):
        if a != b and not (is_version_line(path, old_lines, index) and is_version_line(path, new_lines, index)):
            fail(f"{where}:{index + 1}", "only the CFBundleVersion line may change")
            return


def check_gitignore(where, old, new):
    old_lines, new_lines = old.split("\n"), new.split("\n")
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    for tag, _, _, start, end in matcher.get_opcodes():
        if tag == "equal":
            continue
        if tag != "insert":
            fail(f"{where}:{start + 1}", "changes or removes a line of the snapshot's")
            return
        for number in range(start, end):
            line = new_lines[number].strip()
            if line and not line.startswith("#") and line.lstrip("/") != "project-internal.json" \
                    and not line.lstrip("/").startswith("DerivedData"):
                fail(f"{where}:{number + 1}", "only project-internal.json and DerivedData* lines may be added")
                return


# unflagged-changes.txt

class Entry:
    """One listed change: `path rule [arguments…]` (shell quoting), then its reason on indented lines. The path is
    the repository's (app/…)."""

    def __init__(self, number, words):
        self.number, self.path, self.rule, self.arguments = number, words[0], words[1], words[2:]
        self.reason = []

    def check(self, old, new):
        if self.rule == "any":
            return
        if old is None or new is None:
            fail(self.path, f"{'added' if old is None else 'deleted'}, but its entry in "
                            f"{UNFLAGGED.name} (line {self.number}) lists a change to the file")
            return
        if self.rule == "literal":
            self.check_literal(old, new)
        else:
            self.check_keys(old, new)

    def check_literal(self, old, new):
        """Only lines that swap the old text for the new one differ (a Swift file's after stripping)."""
        before, after = self.arguments
        if self.path.endswith(".swift"):
            result = stripped(self.path, new)
            if result is None:
                return
            lines, numbers = result
        else:
            lines = new.split("\n")
            numbers = list(range(1, len(lines) + 1))
        base = old.split("\n")
        if len(lines) != len(base):
            index = first_difference(lines, base)
            fail(f"{self.path}:{line_of(numbers, index)}",
                 f"differs from the snapshot beyond its entry in {UNFLAGGED.name}")
            return
        for index, (a, b) in enumerate(zip(base, lines)):
            if a != b and (before not in a or a.replace(before, after) != b):
                fail(f"{self.path}:{numbers[index]}", f"differs from the snapshot beyond its entry in {UNFLAGGED.name}")
                return

    def check_keys(self, old, new):
        """A String Catalog with exactly the listed keys removed and added; everything else equal, key by key."""
        try:
            base, catalog = json.loads(old), json.loads(new)
        except ValueError:
            fail(self.path, "not a JSON String Catalog")
            return
        removed = {key[1:] for key in self.arguments if key.startswith("-")}
        added = {key[1:] for key in self.arguments if key.startswith("+")}
        if {k: v for k, v in base.items() if k != "strings"} != {k: v for k, v in catalog.items() if k != "strings"}:
            fail(self.path, "differs from the snapshot outside its strings")
            return
        base_strings, strings = base.get("strings") or {}, catalog.get("strings") or {}
        for key in sorted(removed):
            if key not in base_strings or key in strings:
                fail(self.path, f"a key that {UNFLAGGED.name} (line {self.number}) lists as removed isn't")
        for key in sorted(added):
            if key in base_strings or key not in strings:
                fail(f"{self.path}:{key_line(new, key)}",
                     f"a key that {UNFLAGGED.name} (line {self.number}) lists as added isn't")
        for key in sorted((set(base_strings) | set(strings)) - removed - added):
            if key not in strings:
                fail(self.path, f"a key is removed that {UNFLAGGED.name} doesn't list")
                return
            if base_strings.get(key) != strings[key]:
                change = "added" if key not in base_strings else "changed"
                fail(f"{self.path}:{key_line(new, key)}", f"a key is {change} that {UNFLAGGED.name} doesn't list")
                return


def key_line(text, key):
    """The line where a catalog's entry for `key` starts (0 when it can't be found)."""
    match = re.search(r"^\s*" + re.escape(json.dumps(key)) + r"\s*:", text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def refusal(path, rule):
    """Why `path` (the app's own, ios/…) can't take an entry with `rule`, or None when it can."""
    if path.startswith("ios/DyorKit/") or path.startswith("ios/Internal/"):
        return "ios/DyorKit never changes and ios/Internal always may"
    if path in VERSION_ONLY:
        return "only its CFBundleVersion line may change, and an entry can't widen that"
    if path == GITIGNORE:
        return "only project-internal.json and DerivedData* lines may be added, and an entry can't widen that"
    if path.startswith("ios/DyorHQ/Lite/"):
        return "a Lite file is new and wholly inside #if STELLAR_LITE, and an entry can't widen that"
    if rule == "any" and (path.endswith(".swift") or path.startswith("ios/DyorHQ/")):
        return "a Swift file or an app file can't change in any way: list the change with `literal` (or `keys`)"
    if rule == "keys" and not path.endswith(".xcstrings"):
        return "`keys` is for a String Catalog (.xcstrings)"
    return None


def read_unflagged():
    """{path: Entry}, keyed by the app's own path (ios/…)."""
    entries = {}
    if not UNFLAGGED.exists():
        return entries
    entry = None

    def bad(number, message):
        stop(f"{shown(UNFLAGGED.relative_to(IOS.parent).as_posix())}:{number}: {message}")

    def close(entry):
        if entry and not entry.reason:
            bad(entry.number, "an entry needs a reason, on the indented lines after it")

    for number, line in enumerate(UNFLAGGED.read_text(encoding="utf-8").split("\n"), 1):
        if line[:1].isspace():
            if line.strip():
                if entry is None:
                    bad(number, "an indented line with no entry above it")
                entry.reason.append(line.strip())
            continue
        if not line or line.startswith("#"):
            close(entry)
            entry = None
            continue
        close(entry)
        try:
            words = shlex.split(line)
        except ValueError as error:
            bad(number, str(error))
        if len(words) < 2:
            bad(number, "an entry is `<path> <rule> [arguments…]`")
        entry = Entry(number, words)
        rule, arguments = entry.rule, entry.arguments
        path = entry.path if not PREFIX else entry.path[len(PREFIX) + 1:] if entry.path.startswith(f"{PREFIX}/") else None
        if path is None:
            bad(number, f"{entry.path} isn't under {PREFIX}/: an entry is a path of the app copy, as the check prints it")
        if path in entries:
            bad(number, f"{entry.path} is listed twice")
        if rule not in ("any", "literal", "keys"):
            bad(number, f"unknown rule {rule!r}: any, literal or keys")
        reason = refusal(path, rule)
        if reason:
            bad(number, f"{entry.path} can't be listed: {reason}")
        if rule == "any" and arguments:
            bad(number, "`any` takes no arguments")
        if rule == "literal" and (len(arguments) != 2 or not arguments[0] or arguments[0] == arguments[1]):
            bad(number, "`literal` takes the old text and the new one")
        if rule == "keys" and (not arguments or any(len(key) < 2 or key[0] not in "+-" for key in arguments)):
            bad(number, "`keys` takes the removed keys as -\"key\" and the added ones as +\"key\"")
        entries[path] = entry
    close(entry)
    return entries


# The diff

def name_status(*args):
    """{path: status} from `git diff --name-status` with these arguments."""
    words = git("diff", "--name-status", "--no-renames", "--no-ext-diff", "-z", *args).decode().split("\0")
    return {words[i + 1]: words[i][:1] for i in range(0, len(words) - 1, 2)}


def app_tree(rev):
    """{path: mode} of every file in the base's tree: the app at its root."""
    out = git("ls-tree", "-r", "-z", "--full-tree", rev).decode().split("\0")
    return {line.partition("\t")[2]: line.split(" ", 1)[0] for line in out if line}


def worktree_mode(file):
    if file.is_symlink():
        return "120000"
    if file.is_dir():
        return "160000"
    return "100755" if os.access(file, os.X_OK) else "100644"


def changed_paths(base, worktree):
    """(status, path) for every app path that differs from the base: A added, D deleted, M modified, T type changed.
    Paths are the app's own (ios/…), as they are in the base's tree."""
    head = f"HEAD:{PREFIX}" if PREFIX else "HEAD"
    changes = name_status(base, head)
    if worktree:
        # The commits' changes, then what the working tree changes on top of them, then the files git doesn't track:
        # each is compared with the base itself, so a change that is undone again drops out.
        within = len(PREFIX) + 1 if PREFIX else 0
        scope = f":/{PREFIX}/" if PREFIX else ":/"
        local = [path[within:] for path in name_status("HEAD", "--", scope)]
        untracked = git("ls-files", "--others", "--exclude-standard", "-z", "--full-name", "--", scope).decode()
        candidates = set(changes) | set(local) | {path[within:] for path in untracked.split("\0") if path}
        tree = app_tree(base)
        changes = {}
        for path in candidates:
            file = ROOT / shown(path)
            exists = os.path.lexists(file)
            if path in tree and exists:
                if tree[path] == "160000" or tree[path] != worktree_mode(file) or contents(base, path) != contents(None, path):
                    changes[path] = "M"
            elif path in tree:
                changes[path] = "D"
            elif exists:
                changes[path] = "A"
    return sorted(((status, path) for path, status in changes.items()), key=lambda change: change[1])


class Blobs:
    """Files at a commit, read through one `git cat-file --batch` (a git process per file is slow)."""

    def __init__(self):
        self.process = None

    def read(self, rev, path):
        if self.process is None:
            self.process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE)
        self.process.stdin.write(f"{rev}:{path}\n".encode())
        self.process.stdin.flush()
        header = self.process.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            stop(f"can't read {path} at {rev}")
        data = self.process.stdout.read(int(header[2]))
        self.process.stdout.read(1)  # the newline after each object
        return data


blobs = Blobs()


def contents(rev, path):
    """An app file's text: at the base (`rev`, the app at its root), at HEAD (under app/) or in the working tree (None);
    empty for a directory (a nested repository) and a link's target for a symbolic link."""
    if rev is None:
        file = ROOT / shown(path)
        data = os.readlink(file).encode() if file.is_symlink() else b"" if file.is_dir() else file.read_bytes()
    else:
        data = blobs.read(rev, shown(path) if rev == "HEAD" else path)
    return data.decode("utf-8", errors="surrogateescape")


def is_gitlink(rev, path):
    """Whether `path` is a nested repository: a gitlink (mode 160000) at `rev` (the base, with the app at its root, or
    HEAD, under app/), or a directory in the working tree (None) where a file was expected."""
    if rev is None:
        file = ROOT / shown(path)
        return file.is_dir() and not file.is_symlink()
    out = run_git("ls-tree", "-z", rev, "--", shown(path) if rev == "HEAD" else path, cwd=ROOT)
    return bool(out) and out.split(b" ", 1)[0] == b"160000"


def check_path(status, path, base, worktree, unflagged):
    where = shown(path)
    if path.startswith("ios/DyorKit/"):
        fail(where, "ios/DyorKit is the snapshot's and never changes")
        return
    if path.startswith("ios/Internal/"):
        return
    if status not in "ADMT":
        fail(where, f"git status {status!r}: resolve it first")
        return
    # A nested repository (a gitlink) has no text to compare: it is a finding of its own, whatever the path.
    if is_gitlink(base, path) or is_gitlink(None if worktree else "HEAD", path):
        fail(where, "a nested repository (a git submodule or gitlink): the app copy holds files only")
        return
    old = None if status == "A" else contents(base, path)
    new = None if status == "D" else contents(None if worktree else "HEAD", path)
    # The strict rules first: an entry in unflagged-changes.txt never widens them (read_unflagged refuses those too).
    if status == "A" and path.endswith(".swift"):
        if path.startswith("ios/DyorHQ/Lite/"):
            check_lite_file(where, new)
        else:
            fail(where, "a new Swift file outside ios/DyorHQ/Lite")
    elif status == "A" and path.startswith("ios/DyorHQ/Lite/"):
        # The App Store project builds every file under ios/DyorHQ into the app, so a resource here would ship in it.
        fail(where, "a new file in ios/DyorHQ/Lite that isn't Swift would ship in the App Store app: the internal build's "
                    "resources (string tables, images) go in ios/Internal/Resources")
    elif status == "D" and path.startswith("ios/DyorHQ/"):
        fail(where, "an app file of the snapshot is deleted or renamed")
    elif path in VERSION_ONLY or path == GITIGNORE:
        if status not in "MT":
            fail(where, f"{'added' if status == 'A' else 'deleted'}: only its listed lines may change")
        elif path == GITIGNORE:
            check_gitignore(where, old, new)
        else:
            check_version_only(path, old, new)
    elif path in unflagged:
        unflagged[path].check(old, new)
    elif status in "MT" and path.startswith("ios/DyorHQ/") and path.endswith(".swift"):
        check_app_swift(where, old, new)
    else:
        fail(where, f"{'added' if status == 'A' else 'deleted' if status == 'D' else 'changed'} outside the rules: "
                    f"list it in Internal/{UNFLAGGED.name} with a reason")


# The built app

def is_mach_o(path):
    with path.open("rb") as f:
        return f.read(4) in MACH_O


def check_app(app):
    if not (app / "Info.plist").is_file():
        stop(f"{app} is not an app bundle")
    internal = {name for path in (IOS / "Internal" / "Resources").iterdir() if not path.name.startswith(".")
                for name in resource_names(path.name)}
    for path in sorted(app.rglob("*")):
        where = f"{app.name}/{path.relative_to(app)}"
        if LITE_PRODUCT.match(path.name):
            fail(where, "a Lite package's bundle or binary")
        elif LITE_TABLE.fullmatch(path.name) or path.name in internal:
            fail(where, "a resource of the internal build")
        elif path.is_file() and not path.is_symlink() and is_mach_o(path):
            result = subprocess.run(["nm", "-U", str(path)], capture_output=True, text=True, errors="replace")
            if result.returncode:
                stop(f"nm -U failed on {where}")
            count = sum(1 for line in result.stdout.splitlines() if LITE_SYMBOL.search(line))
            if count:
                fail(where, f"{count} symbols of the Lite packages (nm -U)")


def resource_names(name):
    """The names a resource of Internal/Resources has in a built app: a catalog's tables, any other file as it is."""
    stem, _, extension = name.rpartition(".")
    return [f"{stem}.strings", f"{stem}.stringsdict"] if extension == "xcstrings" else [name]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="a snapshot of the public app, with the app at its root (default: the latest "
                                   f"\"Squashed '{PREFIX}/' …\" commit)")
    ap.add_argument("--worktree", action="store_true", help="check the working tree, not the commits up to HEAD")
    ap.add_argument("--app", type=Path, help="an App Store build's DyorHQ.app (DyorHQ.xcodeproj, Release) to look in")
    args = ap.parse_args()

    try:
        base, label = resolve_base(args.base)
    except LookupError as error:
        stop(str(error))
    unflagged = read_unflagged()
    changes = changed_paths(base, args.worktree)
    for status, path in changes:
        check_path(status, path, base, args.worktree, unflagged)
    if args.app:
        check_app(args.app.resolve())

    for finding in findings:
        print(f"check-build23: {finding}")
    against = "the working tree" if args.worktree else "HEAD"
    app = f", app {args.app.name}" if args.app else ""
    print(f"check-build23: {len(changes)} paths of {PREFIX or '.'}/ differ from the snapshot {label} in {against}{app}: "
          f"{len(findings)} finding{'s' if len(findings) != 1 else ''}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
