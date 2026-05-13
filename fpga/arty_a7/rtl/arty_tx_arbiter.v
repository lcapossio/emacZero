// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// arty_tx_arbiter.v - Fixed 6-input AXIS byte arbiter for the Arty demo
//
// Priority while idle:
//   seq > arp > icmp > stats > udp_echo > udp_blast
//
// The selected owner is held until the output frame's tlast handshake. A
// one-byte register slice decouples the priority mux from the downstream MAC.
// Verilog 2001
// =============================================================================

module arty_tx_arbiter #(
    parameter [7:0]  BLAST_SERVICE_INTERVAL    = 8'd255,
    parameter [11:0] BLAST_SERVICE_IDLE_CYCLES = 12'd2048
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       arp_tx_active,

    input  wire [7:0] seq_tdata,
    input  wire       seq_tvalid,
    output wire       seq_tready,
    input  wire       seq_tlast,

    input  wire [7:0] arp_tdata,
    input  wire       arp_tvalid,
    output wire       arp_tready,
    input  wire       arp_tlast,

    input  wire [7:0] icmp_tdata,
    input  wire       icmp_tvalid,
    output wire       icmp_tready,
    input  wire       icmp_tlast,

    input  wire [7:0] stats_tdata,
    input  wire       stats_tvalid,
    output wire       stats_tready,
    input  wire       stats_tlast,

    input  wire [7:0] udp_tdata,
    input  wire       udp_tvalid,
    output wire       udp_tready,
    input  wire       udp_tlast,

    input  wire [7:0] blast_tdata,
    input  wire       blast_tvalid,
    output wire       blast_tready,
    input  wire       blast_tlast,

    output wire [7:0] m_axis_tdata,
    output wire       m_axis_tvalid,
    input  wire       m_axis_tready,
    output wire       m_axis_tlast
);

    localparam [2:0] OWN_NONE  = 3'b000,
                     OWN_SEQ   = 3'b001,
                     OWN_ARP   = 3'b010,
                     OWN_ICMP  = 3'b011,
                     OWN_UDP   = 3'b100,
                     OWN_BLAST = 3'b101,
                     OWN_STATS = 3'b110;

    reg [2:0]  tx_owner;
    reg [7:0]  blast_service_frame_cnt;
    reg [11:0] blast_service_holdoff;

    wire seq_req   = arp_tx_active && seq_tvalid;
    wire arp_req   = !arp_tx_active && arp_tvalid;
    wire icmp_req  = !arp_tx_active && icmp_tvalid;
    wire stats_req = !arp_tx_active && stats_tvalid;
    wire udp_req   = !arp_tx_active && udp_tvalid;
    wire blast_service_slot = (blast_service_holdoff != 12'd0);
    wire blast_req = !arp_tx_active && !blast_service_slot && blast_tvalid;

    wire [2:0] tx_owner_next =
        (tx_owner == OWN_NONE) ? (seq_req   ? OWN_SEQ
                                : arp_req   ? OWN_ARP
                                : icmp_req  ? OWN_ICMP
                                : stats_req ? OWN_STATS
                                : udp_req   ? OWN_UDP
                                : blast_req ? OWN_BLAST
                                             : OWN_NONE)
                               : tx_owner;

    wire output_frame_done = m_axis_tvalid && m_axis_tready && m_axis_tlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_owner <= OWN_NONE;
            blast_service_frame_cnt <= 8'd0;
            blast_service_holdoff <= 12'd0;
        end else if (output_frame_done) begin
            if (tx_owner_next == OWN_BLAST) begin
                if (blast_service_frame_cnt == BLAST_SERVICE_INTERVAL) begin
                    blast_service_frame_cnt <= 8'd0;
                    blast_service_holdoff <= BLAST_SERVICE_IDLE_CYCLES;
                end else begin
                    blast_service_frame_cnt <= blast_service_frame_cnt + 8'd1;
                end
            end
            tx_owner <= OWN_NONE;
        end else begin
            if (blast_service_holdoff != 12'd0)
                blast_service_holdoff <= blast_service_holdoff - 12'd1;
            tx_owner <= tx_owner_next;
        end
    end

    wire [7:0] mux_tdata  = (tx_owner_next == OWN_SEQ)   ? seq_tdata
                           : (tx_owner_next == OWN_ARP)   ? arp_tdata
                           : (tx_owner_next == OWN_ICMP)  ? icmp_tdata
                           : (tx_owner_next == OWN_STATS) ? stats_tdata
                           : (tx_owner_next == OWN_UDP)   ? udp_tdata
                           : (tx_owner_next == OWN_BLAST) ? blast_tdata
                                                          : 8'd0;
    wire       mux_tvalid = (tx_owner_next == OWN_SEQ)   ? seq_tvalid
                           : (tx_owner_next == OWN_ARP)   ? arp_tvalid
                           : (tx_owner_next == OWN_ICMP)  ? icmp_tvalid
                           : (tx_owner_next == OWN_STATS) ? stats_tvalid
                           : (tx_owner_next == OWN_UDP)   ? udp_tvalid
                           : (tx_owner_next == OWN_BLAST) ? blast_tvalid
                                                          : 1'b0;
    wire       mux_tlast  = (tx_owner_next == OWN_SEQ)   ? seq_tlast
                           : (tx_owner_next == OWN_ARP)   ? arp_tlast
                           : (tx_owner_next == OWN_ICMP)  ? icmp_tlast
                           : (tx_owner_next == OWN_STATS) ? stats_tlast
                           : (tx_owner_next == OWN_UDP)   ? udp_tlast
                           : (tx_owner_next == OWN_BLAST) ? blast_tlast
                                                          : 1'b0;

    wire mux_tready = !m_axis_tvalid || m_axis_tready;

    assign seq_tready   = (tx_owner_next == OWN_SEQ)   ? mux_tready : 1'b0;
    assign arp_tready   = (tx_owner_next == OWN_ARP)   ? mux_tready : 1'b0;
    assign icmp_tready  = (tx_owner_next == OWN_ICMP)  ? mux_tready : 1'b0;
    assign stats_tready = (tx_owner_next == OWN_STATS) ? mux_tready : 1'b0;
    assign udp_tready   = (tx_owner_next == OWN_UDP)   ? mux_tready : 1'b0;
    assign blast_tready = (tx_owner_next == OWN_BLAST) ? mux_tready : 1'b0;

    reg [7:0] m_tdata_r;
    reg       m_tvalid_r;
    reg       m_tlast_r;

    assign m_axis_tdata  = m_tdata_r;
    assign m_axis_tvalid = m_tvalid_r;
    assign m_axis_tlast  = m_tlast_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata_r  <= 8'd0;
            m_tvalid_r <= 1'b0;
            m_tlast_r  <= 1'b0;
        end else if (mux_tready) begin
            m_tdata_r  <= mux_tdata;
            m_tvalid_r <= mux_tvalid;
            m_tlast_r  <= mux_tlast;
        end
    end

endmodule
