#!/usr/bin/env python3
"""Static checks for the MQL5 sources that cannot be compiled on Linux.

The Core headers are exercised for real by tests/scenarios.cpp under g++.
The Broker, UI and Expert files call MetaTrader APIs, so they can only be
checked structurally here. This catches the mistakes that actually happen
when writing MQL5 without MetaEditor: unbalanced braces, an #ifndef with
no #endif, a stray C++ construct MQL5 does not have, and includes that
point at files which are not there.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MQL5 = ROOT / "MQL5"

# Constructs that are valid C++ but not MQL5
FORBIDDEN = [
    (r"\bstd::", "std:: namespace does not exist in MQL5"),
    (r"#include\s*<(vector|string|cstdio|cmath|memory|algorithm)>",
     "C++ standard headers do not exist in MQL5"),
    (r"\bnullptr\b", "MQL5 uses NULL, not nullptr"),
    (r"\bauto\s+\w+\s*=", "MQL5 has no auto type deduction"),
    (r"\busing\s+namespace\b", "MQL5 has no namespaces"),
    (r"\bunsigned\s+(int|char|long|short)\b",
     "MQL5 spells these uint / uchar / ulong / ushort"),
    (r"\bsize_t\b", "MQL5 has no size_t"),
    (r"\bthrow\b", "MQL5 has no exceptions"),
    (r"//.*[؀-ۿ]", "Persian in a code comment; keep source ASCII "
                             "and put Persian in PG_Lang.mqh"),
]

# Files allowed to contain Persian string literals (the UI language table
# and the firm display names)
PERSIAN_OK = {"PG_Lang.mqh", "PG_Firms.mqh", "PG_Panel.mqh"}


def strip_strings_and_comments(text):
    """Blank out string literals and comments so brace counting is honest."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append(' ')
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            out.append(' ')
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check(path):
    problems = []
    raw = path.read_text(encoding="utf-8")
    code = strip_strings_and_comments(raw)

    # balance
    for open_ch, close_ch, label in (('{', '}', 'braces'),
                                     ('(', ')', 'parentheses'),
                                     ('[', ']', 'brackets')):
        d = code.count(open_ch) - code.count(close_ch)
        if d:
            problems.append(f"unbalanced {label}: {d:+d}")

    # include guards on headers
    if path.suffix == ".mqh":
        if code.count("#ifndef") != code.count("#endif"):
            problems.append("#ifndef / #endif mismatch")
        if "#ifndef" not in code:
            problems.append("header has no include guard")

    # forbidden constructs
    for pattern, why in FORBIDDEN:
        target = raw if "Persian" in why else code
        for m in re.finditer(pattern, target):
            line = target[:m.start()].count("\n") + 1
            if "Persian" in why and path.name in PERSIAN_OK:
                continue
            problems.append(f"line {line}: {why} -> {m.group(0)!r}")

    # includes resolve
    for m in re.finditer(r'#include\s*<(PropGuard/[^>]+)>', raw):
        target = MQL5 / "Include" / m.group(1)
        if not target.exists():
            problems.append(f"include not found: {m.group(1)}")

    # every opening brace column-0 function should be closed at column 0-ish
    if code.count("{") and not code.rstrip().endswith(("}", "+", "/")):
        pass  # cosmetic only

    return problems


def main():
    files = sorted(list(MQL5.rglob("*.mqh")) + list(MQL5.rglob("*.mq5")))
    if not files:
        print("no MQL5 sources found")
        return 1

    total = 0
    for f in files:
        problems = check(f)
        rel = f.relative_to(ROOT)
        if problems:
            total += len(problems)
            print(f"\033[31mFAIL\033[0m {rel}")
            for p in problems:
                print(f"       {p}")
        else:
            print(f"\033[32m ok \033[0m {rel}")

    print()
    if total:
        print(f"\033[31m{total} problem(s) found\033[0m")
        return 1
    print(f"\033[32mall {len(files)} MQL5 sources structurally clean\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
