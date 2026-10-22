#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate a CycloneDX 1.5 SBOM for each FuseSoC target in emaczero.core.

Each SBOM lists the files of one target's filesets, plus the files they
`include, with their SHA-256 and SPDX licence (from the file header). The
version and package URL come from the release tag when HEAD has one, else
from the commit. The output is deterministic: the timestamp is the commit
time and the serial number is derived from the package URL and target, so the
same commit always gives the same SBOM.

    python sw/gen_sbom.py --out sbom/        # one <name>-<target>.cdx.json per target
    python sw/gen_sbom.py --check            # validate only, write nothing
    python sw/gen_sbom.py --root ../src --out sbom/   # another checkout (a tag)

--check (build_and_test.py phase 0) fails when a fileset file or an included
file is missing, has no SPDX-License-Identifier, or a target names an unknown
fileset. The parser handles the subset of YAML that emaczero.core uses, so the
script needs only the standard library.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "emaczero.core"
SUPPLIER = "bard0 design"
REPO = "lcapossio/emacZero"
INCLUDE_DIRS = ["rtl"]  # include_dirs of every flow (build scripts, FuseSoC)

INCLUDE = re.compile(r'^\s*`include\s+"([^"]+)"', re.MULTILINE)
SPDX = re.compile(r"SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)")


def parse_core(text: str) -> dict:
    """Minimal parser for emaczero.core: the core name, each fileset's file
    list, and each target's fileset list. Two-space indentation, `- item`
    lists and `[a, b]` inline lists, as the file is written."""
    name = None
    filesets, targets = {}, {}
    section = sub = key = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        ind = len(line) - len(line.lstrip(" "))
        s = line.strip()
        if ind == 0:
            section, sub, key = s.split(":", 1)[0], None, None
            if section == "name":
                name = s.split(":", 1)[1].strip()
        elif ind == 2 and section in ("filesets", "targets"):
            sub, key = s.rstrip(":"), None
            (filesets if section == "filesets" else targets)[sub] = {}
        elif ind == 4 and sub is not None:
            k, _, v = s.partition(":")
            key, v = k.strip(), v.strip()
            entry = (filesets if section == "filesets" else targets)[sub]
            if v.startswith("[") and v.endswith("]"):
                entry[key] = [x.strip() for x in v[1:-1].split(",") if x.strip()]
            elif v:
                entry[key] = v
            else:
                entry[key] = []
        elif ind == 6 and s.startswith("- ") and sub is not None and key:
            entry = (filesets if section == "filesets" else targets)[sub]
            if isinstance(entry.get(key), list):
                entry[key].append(s[2:].strip())
    if not name or not filesets or not targets:
        raise ValueError("emaczero.core: could not find name, filesets and targets")
    return {"name": name, "filesets": filesets, "targets": targets}


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True,
                          check=True).stdout.strip()


def includes(path: Path, errors: list) -> list:
    """Repo-relative paths of the files `path` `includes, resolved like the flows do."""
    found = []
    for inc in INCLUDE.findall(path.read_text(encoding="utf-8", errors="replace")):
        for d in [path.parent.relative_to(ROOT).as_posix()] + INCLUDE_DIRS:
            if (ROOT / d / inc).is_file():
                found.append(f"{d}/{inc}")
                break
        else:
            errors.append(f"{path.relative_to(ROOT).as_posix()}: `include \"{inc}\" not found")
    return found


def file_component(rel: str, fileset: str, errors: list) -> dict:
    data = (ROOT / rel).read_bytes()
    lic = SPDX.search(data[:2048].decode("utf-8", errors="replace"))
    if not lic:
        errors.append(f"{rel}: no SPDX-License-Identifier in its header")
    comp = {
        "type": "file",
        "bom-ref": f"file:{rel}",
        "name": rel,
        "hashes": [{"alg": "SHA-256", "content": hashlib.sha256(data).hexdigest()}],
        "properties": [{"name": "emaczero:fileset", "value": fileset}],
    }
    if lic:
        comp["licenses"] = [{"license": {"id": lic.group(1)}}]
    return comp


def build(core: dict, target: str, ident: dict, errors: list) -> dict:
    comps, seen = [], set()

    def add(rel: str, fileset: str):
        if rel in seen:
            return
        if not (ROOT / rel).is_file():
            errors.append(f"{target}: {rel} (fileset {fileset}) does not exist")
            return
        seen.add(rel)
        comps.append(file_component(rel, fileset, errors))
        for inc in includes(ROOT / rel, errors):
            add(inc, f"{fileset} (included)")

    for fs in core["targets"][target].get("filesets", []):
        if fs not in core["filesets"]:
            errors.append(f"target {target}: unknown fileset {fs}")
            continue
        for rel in core["filesets"][fs].get("files", []):
            add(rel, fs)

    purl = f"pkg:github/{REPO}@{ident['version']}"
    root = {
        "type": "library",
        "bom-ref": purl,
        "supplier": {"name": SUPPLIER},
        "name": "emacZero",
        "version": ident["version"],
        "description": f"emacZero Ethernet MAC, FuseSoC target '{target}' "
                       f"(top: {core['targets'][target].get('toplevel', '?')})",
        "licenses": [{"license": {"id": "Apache-2.0"}}],
        "purl": purl,
        "externalReferences": [{"type": "vcs", "url": f"https://github.com/{REPO}"}],
        "properties": [
            {"name": "emaczero:fusesoc-vlnv", "value": core["name"]},
            {"name": "emaczero:fusesoc-target", "value": target},
            {"name": "emaczero:git-commit", "value": ident["commit"]},
        ],
    }
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{purl}#{target}")),
        "version": 1,
        "metadata": {
            "timestamp": ident["time"],
            "tools": {"components": [{"type": "application", "name": "sw/gen_sbom.py",
                                      "version": ident["commit"]}]},
            "component": root,
        },
        "components": comps,
        "dependencies": [{"ref": purl, "dependsOn": [c["bom-ref"] for c in comps]}],
    }


def identity() -> dict:
    commit = git("rev-parse", "HEAD")
    try:
        version = git("describe", "--tags", "--exact-match", "HEAD")
    except subprocess.CalledProcessError:
        version = commit
    # Commit time in UTC, the format CycloneDX expects.
    time = git("show", "-s", "--format=%cd", "--date=format-local:%Y-%m-%dT%H:%M:%SZ", "HEAD")
    return {"commit": commit, "version": version, "time": time}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--out", type=Path, help="directory to write the SBOMs to")
    g.add_argument("--check", action="store_true", help="validate only, write nothing")
    ap.add_argument("--target", action="append", help="only these targets (default: all)")
    ap.add_argument("--root", type=Path, help="checkout to describe (default: this repository)")
    args = ap.parse_args()
    global ROOT, CORE
    if args.root:
        ROOT = args.root.resolve()
        CORE = ROOT / "emaczero.core"

    core = parse_core(CORE.read_text(encoding="utf-8"))
    targets = args.target or list(core["targets"])
    ident = identity() if not args.check else {"commit": "0" * 40, "version": "check",
                                               "time": "1970-01-01T00:00:00Z"}
    errors, boms = [], {}
    for t in targets:
        if t not in core["targets"]:
            errors.append(f"unknown target {t}")
            continue
        boms[t] = build(core, t, ident, errors)
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        return 1
    stem = core["name"].split(":")[2]
    for t, bom in boms.items():
        n = len(bom["components"])
        if args.check:
            print(f"{t}: {n} files")
            continue
        args.out.mkdir(parents=True, exist_ok=True)
        path = args.out / f"{stem}-{ident['version']}-{t}.cdx.json"
        path.write_text(json.dumps(bom, indent=2) + "\n", encoding="utf-8", newline="\n")
        print(f"{path.as_posix()}: {n} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
