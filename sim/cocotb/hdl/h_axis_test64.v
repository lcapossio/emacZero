// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_axis_test64.v - cocotb harness: axis_test_gen64 and axis_test_chk64 side
// by side, not connected, so the test can read the generator's frames and
// write its own (good and broken ones) into the checker.
// Verilog 2001
// =============================================================================

module h_axis_test64 (
    input  wire        clk,
    input  wire        rst_n,

    // generator
    input  wire        g_enable,
    input  wire [15:0] g_len,
    input  wire        g_sweep,
    input  wire        g_udp,
    input  wire        g_csum_junk,
    input  wire [7:0]  g_ipg,
    input  wire        g_inj_err,
    output wire [63:0] g_tdata,
    output wire [7:0]  g_tkeep,
    output wire        g_tvalid,
    output wire        g_tlast,
    input  wire        g_tready,
    output wire [31:0] g_frames,

    // checker
    input  wire        c_clear,
    input  wire        c_udp,
    input  wire        c_csum,
    input  wire [63:0] c_tdata,
    input  wire [7:0]  c_tkeep,
    input  wire        c_tvalid,
    input  wire        c_tlast,
    input  wire        c_tuser,
    output wire [31:0] c_good,
    output wire [31:0] c_bad,
    output wire [31:0] c_tuser_frames,
    output wire [31:0] c_seq_gaps
);

    axis_test_gen64 u_gen (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (g_enable),
        .len           (g_len),
        .sweep         (g_sweep),
        .udp           (g_udp),
        .csum_junk     (g_csum_junk),
        .ipg           (g_ipg),
        .inj_err       (g_inj_err),
        .m_axis_tdata  (g_tdata),
        .m_axis_tkeep  (g_tkeep),
        .m_axis_tvalid (g_tvalid),
        .m_axis_tlast  (g_tlast),
        .m_axis_tready (g_tready),
        .frames        (g_frames)
    );

    axis_test_chk64 u_chk (
        .clk           (clk),
        .rst_n         (rst_n),
        .clear         (c_clear),
        .udp           (c_udp),
        .csum          (c_csum),
        .s_axis_tdata  (c_tdata),
        .s_axis_tkeep  (c_tkeep),
        .s_axis_tvalid (c_tvalid),
        .s_axis_tlast  (c_tlast),
        .s_axis_tuser  (c_tuser),
        .good_frames   (c_good),
        .bad_frames    (c_bad),
        .tuser_frames  (c_tuser_frames),
        .seq_gaps      (c_seq_gaps),
        .good_pulse    (),
        .bad_pulse     ()
    );

endmodule
