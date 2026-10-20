#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Check that the Si5328 I2C ROM is the same in Verilog and VHDL.

fpga/zcu106/rtl/zcu106_si5328_rom.vh (included by i2c_init.v) and
fpga/zcu106/rtl/zcu106_si5328_rom_pkg.vhd (used by i2c_init.vhd) each hold the
table by hand. This script parses both and compares ROM_LEN, the two Si5328
address bytes, and every entry (index, last, b0, b1, b2) including the
default one, plus the comment on each entry. The formal proof in parity.yml
also proves the tables equal; this check is quicker and says which entry
differs.

    python sim/parity/i2c_init/check_rom.py     # exit 1 if they differ
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
VH = ROOT / "fpga/zcu106/rtl/zcu106_si5328_rom.vh"
PKG = ROOT / "fpga/zcu106/rtl/zcu106_si5328_rom_pkg.vhd"


def _byte(tok: str):
    """'si', or an int from 8'hXX / 8'dN / x"XX" / d8(N)."""
    tok = tok.strip()
    if tok == "si":
        return "si"
    for pat, base in ((r"8'h([0-9A-Fa-f]+)", 16), (r"8'd(\d+)", 10),
                      (r'x"([0-9A-Fa-f]+)"', 16), (r"d8\((\d+)\)", 10)):
        m = re.fullmatch(pat, tok)
        if m:
            val = int(m.group(1), base)
            if val > 255:
                raise SystemExit(f"byte out of range: {tok}")
            return val
    raise SystemExit(f"cannot parse byte '{tok}'")


def _key(idx: str):
    return "default" if idx in ("default", "others") else int(idx)


def parse_vh(text: str):
    rom_len = int(re.search(r"localparam\s+ROM_LEN\s*=\s*(\d+)\s*;", text).group(1))
    m = re.search(r"si\s*=\s*alt\s*\?\s*(8'h\w+)\s*:\s*(8'h\w+)\s*;", text)
    si = (_byte(m.group(1)), _byte(m.group(2)))          # (alt=1, alt=0)
    entries = {}
    for m in re.finditer(r"^\s*(?:16'd(\d+)|(default))\s*:\s*rom_entry\s*=\s*"
                         r"\{2'd(\d),\s*([^,]+),\s*([^,]+),\s*([^}]+)\}\s*;[ \t]*(?://\s*(.*))?$",
                         text, re.MULTILINE):
        idx = _key(m.group(1) or m.group(2))
        entries[idx] = (int(m.group(3)), *(_byte(m.group(k)) for k in (4, 5, 6)),
                        (m.group(7) or "").strip())
    return rom_len, si, entries


def parse_pkg(text: str):
    rom_len = int(re.search(r"constant\s+ROM_LEN\s*:\s*integer\s*:=\s*(\d+)\s*;", text).group(1))
    m = re.search(r"if\s+alt\s*=\s*'1'\s+then\s+si\s*:=\s*(x\"\w+\")\s*;\s*"
                  r"else\s+si\s*:=\s*(x\"\w+\")\s*;", text)
    si = (_byte(m.group(1)), _byte(m.group(2)))
    entries = {}
    for m in re.finditer(r"^\s*when\s+(\d+|others)\s*=>\s*e\s*:=\s*ent\((\d),\s*([^,]+),\s*"
                         r"([^,]+),\s*([^;]+)\)\s*;[ \t]*(?:--\s*(.*))?$", text, re.MULTILINE):
        idx = _key(m.group(1))
        entries[idx] = (int(m.group(2)), *(_byte(m.group(k)) for k in (3, 4, 5)),
                        (m.group(6) or "").strip())
    return rom_len, si, entries


def main() -> int:
    v_len, v_si, v_ent = parse_vh(VH.read_text(encoding="utf-8"))
    p_len, p_si, p_ent = parse_pkg(PKG.read_text(encoding="utf-8"))
    errors = []
    if v_len != p_len:
        errors.append(f"ROM_LEN: .vh {v_len}, pkg {p_len}")
    if v_si != p_si:
        errors.append(f"si (alt=1, alt=0): .vh {v_si}, pkg {p_si}")
    if len(v_ent) != v_len or "default" not in v_ent:
        errors.append(f".vh: parsed {len(v_ent)} entries, expected {v_len} incl. default")
    for idx in sorted(set(v_ent) | set(p_ent), key=str):
        if v_ent.get(idx) != p_ent.get(idx):
            errors.append(f"entry {idx}: .vh {v_ent.get(idx)}, pkg {p_ent.get(idx)}")
    if errors:
        print(f"{VH.name} and {PKG.name} differ:")
        for e in errors:
            print("  " + e)
        return 1
    print(f"{VH.name} == {PKG.name}: ROM_LEN {v_len}, {len(v_ent)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
