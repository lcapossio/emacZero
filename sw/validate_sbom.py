#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Validate CycloneDX 1.5 JSON SBOMs against the official schema (strict).

    pip install -r .github/requirements/sbom.txt
    python sw/validate_sbom.py sbom/*.cdx.json

Used by the release workflow before it attaches the SBOMs to a release.
"""

import sys

from cyclonedx.schema import SchemaVersion
from cyclonedx.validation.json import JsonStrictValidator


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    validator = JsonStrictValidator(SchemaVersion.V1_5)
    bad = 0
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as f:
            err = validator.validate_str(f.read())
        print(f"{path}: {'valid' if err is None else err}")
        bad += err is not None
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
