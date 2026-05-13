// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// version.vh - Single source of truth for the emacZero version.
//
// The VERSION CSR (axilite_regs.v, offset 0x00) is built from these defines.
// Any change here must be mirrored in:
//   sw/emaczero/emaczero.h  (EMZ_VERSION_MAJOR / MINOR / ID)
//   emaczero.core           (name: bard0:eth:emaczero:<MAJOR>.<MINOR>.0)
// build_and_test.py runs a consistency check that fails if any of the three
// disagree.
// =============================================================================
`ifndef EMACZERO_VERSION_VH
`define EMACZERO_VERSION_VH

`define EMZ_VERSION_MAJOR 8'h00
`define EMZ_VERSION_MINOR 8'h01
`define EMZ_VERSION_ID    16'h454D  // ASCII "EM"

`endif // EMACZERO_VERSION_VH
