#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Check the sensitivity lists of combinational VHDL processes.

A VHDL-93 process with an incomplete sensitivity list simulates as a latch:
it does not wake up when a signal it reads changes. Synthesis ignores the
list, so the translateHDL proofs (which run on synthesised netlists) cannot
see the mismatch; only simulation can, and only on the paths it drives. This
script reports, for every process that has a sensitivity list and no clock
edge, each signal or input port it reads but does not list.

It is a lexical heuristic, not a VHDL parser: it scopes names per
architecture (that architecture's signals plus its entity's in/inout ports),
strips comments, drops names declared locally as constants, variables or
loop indices, and treats a name as read when it appears anywhere other than
the target of a signal assignment. It can over-report (then fix the list or
rename), and it does not look inside functions or procedures.

    python sim/parity/sens_check.py               # every *.vhd in the repo
    python sim/parity/sens_check.py a.vhd b.vhd   # just these
Exit 1 when anything is reported (build_and_test phase 0d).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEARCH = ["rtl/vhdl", "fpga", "sim/parity"]

ID = re.compile(r"\b[A-Za-z][A-Za-z0-9_]*\b")
NAMES = r"([A-Za-z][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z][A-Za-z0-9_]*)*)"


def split_names(s: str) -> set:
    return {n.strip().lower() for n in s.split(",") if n.strip()}


def strip_comments(t: str) -> str:
    # String literals in this code base never contain "--".
    return "\n".join(line.split("--", 1)[0] for line in t.splitlines())


def entity_inputs(t: str) -> dict:
    """entity name -> its in/inout port names."""
    ents = {}
    for m in re.finditer(r"\bentity\s+(\w+)\s+is\b(.*?)\bend\b(\s+entity)?(\s+\w+)?\s*;",
                         t, re.I | re.S):
        names = set()
        port = re.search(r"\bport\s*\((.*)\)\s*;", m.group(2), re.I | re.S)
        if port:
            for p in re.finditer(NAMES + r"\s*:\s*(in|inout)\b", port.group(1), re.I):
                names |= split_names(p.group(1))
        ents[m.group(1).lower()] = names
    return ents


def architectures(t: str):
    """(entity name, architecture text) for each architecture in the file."""
    starts = [m for m in re.finditer(r"\barchitecture\s+\w+\s+of\s+(\w+)\s+is\b", t, re.I)]
    for k, m in enumerate(starts):
        end = starts[k + 1].start() if k + 1 < len(starts) else len(t)
        yield m.group(1).lower(), m.end(), t[m.end():end]


def check_file(path: Path) -> list:
    t = strip_comments(path.read_text(encoding="utf-8"))
    ents = entity_inputs(t)
    out = []
    for ent, base, arch in architectures(t):
        sigs = set(ents.get(ent, set()))
        for m in re.finditer(r"\bsignal\s+" + NAMES + r"\s*:", arch, re.I):
            sigs |= split_names(m.group(1))
        for m in re.finditer(r"\bprocess\s*\(([^)]*)\)(.*?)\bend\s+process\b", arch, re.I | re.S):
            body = m.group(2)
            if re.search(r"rising_edge|falling_edge|'event", body, re.I):
                continue
            sens = split_names(m.group(1))
            local = set()
            for d in re.finditer(r"\b(?:variable|constant)\s+" + NAMES + r"\s*:", body, re.I):
                local |= split_names(d.group(1))
            for d in re.finditer(r"\bfor\s+(\w+)\s+in\b", body, re.I):
                local.add(d.group(1).lower())
            missing = []
            for s in sorted(({i.lower() for i in ID.findall(body)} & sigs) - sens - local):
                uses = len(re.findall(rf"\b{s}\b", body, re.I))
                # A target starts a statement; "if a <= b" reads a.
                targets = len(re.findall(rf"(?:^|;|\bthen\b|\belse\b|\bbegin\b|=>)\s*"
                                         rf"{s}\s*(?:\([^)]*\))?\s*<=", body, re.I | re.M))
                if uses > targets:
                    missing.append(s)
            if missing:
                line = t[:base + m.start()].count("\n") + 1
                name = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else path
                out.append(f"{name}:{line}: process does not list {', '.join(missing)}")
    return out


def main() -> int:
    if len(sys.argv) > 1:
        files = [Path(a).resolve() for a in sys.argv[1:]]
    else:
        files = sorted(p for d in SEARCH for p in (ROOT / d).rglob("*.vhd"))
    report = [r for f in files for r in check_file(f)]
    for r in report:
        print(r)
    print(f"{len(files)} files, {len(report)} incomplete sensitivity list(s)")
    return 1 if report else 0


if __name__ == "__main__":
    sys.exit(main())
