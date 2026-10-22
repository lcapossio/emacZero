#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate a CycloneDX 1.5 SBOM for each FuseSoC target in emaczero.core.

Each SBOM lists the files of one target's filesets, plus the files they
`include, with their SHA-256 and SPDX licence (from the file header). Files
are read from the commit (git blobs), not the working tree, so the hashes do
not depend on local edits or on the checkout's line endings. The version is
--version (a tag that must point at HEAD), else the tag on HEAD (the highest
in version order when there are several), else the commit hash. The output is
deterministic: the timestamp is the commit time in UTC and the serial number
is derived from the package URL and target, so the same commit and version
always give the same SBOM.

    python sw/gen_sbom.py --out sbom/        # one <name>-<version>-<target>.cdx.json per target
    python sw/gen_sbom.py --check            # validate the working tree, write nothing
    python sw/gen_sbom.py --root ../src --version v0.2.0 --out sbom/   # another checkout

--check (build_and_test.py phase 0) reads the working tree, so it also sees
files not committed yet. It fails when a fileset file or an included file is
missing, has no SPDX-License-Identifier, or a target names an unknown fileset.
The parser handles the subset of YAML that emaczero.core uses, so the script
needs only the standard library.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

TOOL_ROOT = Path(__file__).resolve().parents[1]  # the checkout this script comes from
ROOT = TOOL_ROOT                                  # the checkout described (--root)
SUPPLIER = "bard0 design"
REPO = "lcapossio/emacZero"
PURL_REPO = REPO.lower()  # GitHub package URLs are lowercase
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


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd or ROOT, capture_output=True, text=True,
                          check=True).stdout.strip()


class WorkTree:
    """Files as they are on disk (--check)."""

    def exists(self, rel: str) -> bool:
        return (ROOT / rel).is_file()

    def read(self, rel: str) -> bytes:
        return (ROOT / rel).read_bytes()


class Commit:
    """Files as committed at HEAD: the bytes git stores, whatever the
    checkout's line endings or local edits."""

    def __init__(self):
        out = subprocess.run(["git", "ls-tree", "-r", "-z", "--name-only", "HEAD"], cwd=ROOT,
                             capture_output=True, check=True).stdout
        self.files = set(out.decode("utf-8").split("\0")) - {""}

    def exists(self, rel: str) -> bool:
        return rel in self.files

    def read(self, rel: str) -> bytes:
        return subprocess.run(["git", "cat-file", "blob", f"HEAD:{rel}"], cwd=ROOT,
                              capture_output=True, check=True).stdout


def includes(src, rel: str, errors: list) -> list:
    """Repo-relative paths of the files `rel` `includes, resolved like the flows do."""
    found = []
    here = rel.rsplit("/", 1)[0] if "/" in rel else ""
    for inc in INCLUDE.findall(src.read(rel).decode("utf-8", errors="replace")):
        for d in [here] + INCLUDE_DIRS:
            cand = f"{d}/{inc}" if d else inc
            if src.exists(cand):
                found.append(cand)
                break
        else:
            errors.append(f"{rel}: `include \"{inc}\" not found")
    return found


def file_component(src, rel: str, fileset: str, errors: list) -> dict:
    data = src.read(rel)
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


def build(src, core: dict, target: str, ident: dict, errors: list) -> dict:
    comps, seen = [], set()

    def add(rel: str, fileset: str):
        if rel in seen:
            return
        if not src.exists(rel):
            errors.append(f"{target}: {rel} (fileset {fileset}) does not exist")
            return
        seen.add(rel)
        comps.append(file_component(src, rel, fileset, errors))
        for inc in includes(src, rel, errors):
            add(inc, f"{fileset} (included)")

    for fs in core["targets"][target].get("filesets", []):
        if fs not in core["filesets"]:
            errors.append(f"target {target}: unknown fileset {fs}")
            continue
        for rel in core["filesets"][fs].get("files", []):
            add(rel, fs)

    # Package URL: lowercase repository, version percent-encoded (a tag may
    # hold '/', '#' or '+').
    purl = f"pkg:github/{PURL_REPO}@{quote(ident['version'], safe='.-_~')}"
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
                                      "version": ident["tool_commit"]}]},
            "component": root,
        },
        "components": comps,
        "dependencies": [{"ref": purl, "dependsOn": [c["bom-ref"] for c in comps]}],
    }


def identity(version: str | None = None) -> dict:
    commit = git("rev-parse", "HEAD")
    if version:
        try:
            tagged = git("rev-parse", "--verify", "--quiet", f"refs/tags/{version}^{{commit}}")
        except subprocess.CalledProcessError:
            tagged = None
        if tagged != commit:
            raise ValueError(f"--version {version}: not a tag on HEAD ({commit})")
    else:
        # Several tags on one commit: take the highest in version order, so the
        # choice does not depend on tag type or creation date.
        tags = git("tag", "--points-at", "HEAD", "--sort=-v:refname").splitlines()
        version = tags[0] if tags else commit
    # Commit time in UTC, the format CycloneDX expects.
    epoch = int(git("show", "-s", "--format=%ct", "HEAD"))
    time = datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # The generator's own commit, which differs from the described one when
    # --root points at another checkout (an older tag).
    try:
        tool_commit = git("rev-parse", "HEAD", cwd=TOOL_ROOT)
    except (subprocess.CalledProcessError, OSError):
        tool_commit = "unknown"
    return {"commit": commit, "version": version, "time": time, "tool_commit": tool_commit}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--out", type=Path, help="directory to write the SBOMs to")
    g.add_argument("--check", action="store_true", help="validate only, write nothing")
    ap.add_argument("--target", action="append", help="only these targets (default: all)")
    ap.add_argument("--root", type=Path, help="checkout to describe (default: this repository)")
    ap.add_argument("--version", help="release tag to name the SBOMs after; it must point at "
                                      "HEAD (default: the tag on HEAD, else the commit)")
    args = ap.parse_args()
    global ROOT
    if args.root:
        ROOT = args.root.resolve()

    if args.check:
        src = WorkTree()
        ident = {"commit": "0" * 40, "version": "check", "time": "1970-01-01T00:00:00Z",
                 "tool_commit": "0" * 40}
    else:
        try:
            ident = identity(args.version)
        except ValueError as e:
            print(f"ERROR: {e}")
            return 1
        src = Commit()
    if not src.exists("emaczero.core"):
        print(f"ERROR: {ROOT}: no emaczero.core")
        return 1
    core = parse_core(src.read("emaczero.core").decode("utf-8"))
    targets = args.target or list(core["targets"])
    errors, boms = [], {}
    for t in targets:
        if t not in core["targets"]:
            errors.append(f"unknown target {t}")
            continue
        boms[t] = build(src, core, t, ident, errors)
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        return 1
    stem = core["name"].split(":")[2]
    # One path segment, reversible: a tag such as release/v1 or v1#2 is
    # percent-encoded rather than split into directories or read by
    # `gh release upload` as a display label.
    fver = quote(ident["version"], safe=".-_+~")
    for t, bom in boms.items():
        n = len(bom["components"])
        if args.check:
            print(f"{t}: {n} files")
            continue
        args.out.mkdir(parents=True, exist_ok=True)
        path = args.out / f"{stem}-{fver}-{t}.cdx.json"
        path.write_text(json.dumps(bom, indent=2) + "\n", encoding="utf-8", newline="\n")
        print(f"{path.as_posix()}: {n} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
