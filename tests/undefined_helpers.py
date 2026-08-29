#!/usr/bin/env python3
"""Fail if a Lua file calls a PROJECT helper that it does not define itself.

WHY: a call to an undefined local helper is a nil-global lookup. It RAISES, the enclosing pcall
swallows it, and the feature silently never runs — no error line, no clue.

`safe()` was called four times in RealisticEvents.lua while only being defined in Realistic.lua.
That single omission disabled the role-cache refresher, BOTH speaker-election paths of the
squadmate death callout, and the say() itself. Nothing errored. Nothing fired. It cost two full
game restarts to find, and it is invisible to luajit because it is a runtime lookup.

CONTRACT — deliberately narrow. It considers only the project's OWN helper vocabulary: names
defined as `local function <name>` in any of the files passed in. For each file, every call to a
name in that vocabulary must be defined in THAT file. Engine globals, Lua builtins, loop
variables and string contents are all irrelevant, so this cannot produce the noise a general
"undefined identifier" scan does. A noisy check gets ignored, and an ignored check is worse than
no check.

Usage: undefined_helpers.py <file.lua> [file.lua ...]
"""
import re
import sys

DEF = re.compile(r"^\s*local\s+function\s+([A-Za-z_]\w*)", re.M)
# a bare call: name( not preceded by '.', ':' or another word character
CALL = re.compile(r"(?<![\w.:])([a-z_]\w*)\s*\(")


def strip_noise(src: str) -> str:
    """Drop comments and string literals — both contain words followed by '(' that are not calls."""
    src = "\n".join(re.sub(r"--.*$", "", line) for line in src.split("\n"))
    src = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', src)
    src = re.sub(r"'(?:[^'\\\n]|\\.)*'", "''", src)
    return src


def main() -> int:
    files = {p: strip_noise(open(p).read()) for p in sys.argv[1:]}
    # the project's helper vocabulary: every `local function` name across all files
    vocabulary = set()
    for src in files.values():
        vocabulary |= set(DEF.findall(src))

    bad = False
    for path, src in files.items():
        defined_here = set(DEF.findall(src))
        called_here = set(CALL.findall(src))
        missing = sorted((called_here & vocabulary) - defined_here)
        if missing:
            bad = True
            print("  \033[31mFAIL\033[0m  %s calls a project helper it does not define: %s"
                  % (path, ", ".join(missing)))
    if not bad:
        print("  \033[32mPASS\033[0m  every project helper called is defined in its own file")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
