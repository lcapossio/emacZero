// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity include shim. fpga/zcu106/rtl/i2c_init.v does
// `include "zcu106_si5328_rom.vh"; Yosys finds it next to the including file,
// but iverilog (L1 lint) searches only the working directory (this manifest's
// dir) and -I paths, and the manifest has no include-dir key. Forward to the
// single source of truth - do not copy the table.
`include "../../../fpga/zcu106/rtl/zcu106_si5328_rom.vh"
