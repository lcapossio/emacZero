// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_tx.v - Ethernet MAC Transmit Path
// Adds preamble/SFD, pads to 64 bytes minimum, appends CRC
// Verilog 2001
// =============================================================================

module eth_mac_tx #(
    parameter MAX_FRAME = 9018      // jumbo MTU + headers; standard Ethernet
                                    // is 1518; raise for jumbo frame use
)(
    input  wire        clk,
    input  wire        rst_n,
    // Sampled only in S_IDLE so downstream pressure can delay a new frame
    // without ever stalling an in-flight Ethernet transmission.
    input  wire        tx_start_ok,

    // GMII TX interface (to RGMII or direct PHY)
    output reg  [7:0]  gmii_txd,
    output reg         gmii_tx_en,
    output reg         gmii_tx_er,

    // Frame data input (complete Ethernet frame: dst+src+type+payload)
    // Caller provides raw frame content; this module adds preamble/SFD and CRC
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [0:0]  s_axis_tkeep,

    // Status
    output reg         tx_active,
    // Debug
    output wire [3:0]  dbg_state,
    output wire [3:0]  dbg_stall_cnt
);

    localparam [3:0]
        S_IDLE     = 4'd0,
        S_PREAMBLE = 4'd1,
        S_SFD      = 4'd2,
        S_DATA     = 4'd3,
        S_PAD      = 4'd4,
        S_CRC      = 4'd5,
        S_IFG      = 4'd6;

    localparam PREAMBLE_LEN = 7;
    localparam MIN_FRAME    = 60;
    localparam IFG_BYTES    = 12;

    reg [3:0]  state;
    reg [3:0]  count;
    reg [13:0] data_cnt;
    reg [3:0]  stall_cnt;

    assign dbg_state     = state;
    assign dbg_stall_cnt = stall_cnt;

    wire [31:0] crc_out;
    wire [31:0] crc_raw;
    reg         crc_init;
    reg         crc_data_valid;
    reg  [7:0]  crc_data_in;
    reg  [31:0] crc_saved;
    reg  [31:0] crc_accum;
    reg  [7:0]  first_data;
    reg         first_last;
    reg         have_first;

    function [31:0] crc_step_byte;
        input [31:0] crc_in;
        input [7:0]  data;
        integer i;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'd0, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0])
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
            end
            crc_step_byte = c;
        end
    endfunction

    crc32 u_crc (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (crc_data_in),
        .data_valid(crc_data_valid),
        .crc_init  (crc_init),
        .crc_out   (crc_out),
        .crc_raw   (crc_raw)
    );

    reg frame_ended;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            count          <= 4'd0;
            data_cnt       <= 14'd0;
            gmii_txd       <= 8'd0;
            gmii_tx_en     <= 1'b0;
            gmii_tx_er     <= 1'b0;
            s_axis_tready  <= 1'b0;
            tx_active      <= 1'b0;
            crc_init       <= 1'b0;
            crc_data_valid <= 1'b0;
            crc_data_in    <= 8'd0;
            crc_saved      <= 32'd0;
            crc_accum      <= 32'hFFFFFFFF;
            frame_ended    <= 1'b0;
            stall_cnt      <= 4'd0;
            first_data     <= 8'd0;
            first_last     <= 1'b0;
            have_first     <= 1'b0;
        end else begin
            crc_init       <= 1'b0;
            crc_data_valid <= 1'b0;
            s_axis_tready  <= 1'b0;
            gmii_tx_er     <= 1'b0;

            case (state)
                S_IDLE: begin
                    gmii_tx_en  <= 1'b0;
                    tx_active   <= 1'b0;
                    frame_ended <= 1'b0;
                    stall_cnt   <= 4'd0;
                    have_first  <= 1'b0;
                    s_axis_tready <= (tx_start_ok !== 1'b0);
                    if (s_axis_tvalid && s_axis_tready && (tx_start_ok !== 1'b0)) begin
                        first_data <= s_axis_tdata;
                        first_last <= s_axis_tlast;
                        have_first <= 1'b1;
                        s_axis_tready <= 1'b0;
                        state     <= S_PREAMBLE;
                        count     <= 4'd0;
                        crc_init  <= 1'b1;
                        crc_accum <= 32'hFFFFFFFF;
                        tx_active <= 1'b1;
                    end
                end

                S_PREAMBLE: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= 8'h55;
                    stall_cnt  <= 4'd0;
                    count      <= count + 4'd1;
                    if (count == PREAMBLE_LEN - 1)
                        state <= S_SFD;
                end

                S_SFD: begin
                    gmii_txd      <= 8'hD5;
                    data_cnt      <= 14'd0;
                    stall_cnt     <= 4'd0;
                    state         <= S_DATA;
                end

                S_DATA: begin
                    if (frame_ended) begin
                        stall_cnt <= 4'd0;
                        if (data_cnt < MIN_FRAME) begin
                            state          <= S_PAD;
                            gmii_txd       <= 8'h00;
                            crc_data_valid <= 1'b1;
                            crc_data_in    <= 8'h00;
                            crc_accum      <= crc_step_byte(crc_accum, 8'h00);
                            data_cnt       <= data_cnt + 14'd1;
                        end else begin
                            // crc_saved was precomputed when the final data byte
                            // was accepted, so it already includes that byte.
                            state     <= S_CRC;
                            count     <= 4'd1;
                            gmii_txd  <= crc_saved[7:0];
                        end
                    end else if (have_first) begin
                        stall_cnt      <= 4'd0;
                        gmii_txd       <= first_data;
                        crc_data_valid <= 1'b1;
                        crc_data_in    <= first_data;
                        crc_accum      <= crc_step_byte(crc_accum, first_data);
                        data_cnt       <= data_cnt + 14'd1;
                        have_first     <= 1'b0;
                        if (first_last) begin
                            crc_saved   <= ~crc_step_byte(crc_accum, first_data);
                            frame_ended <= 1'b1;
                        end else if (data_cnt >= MAX_FRAME - 1) begin
                            gmii_tx_er <= 1'b1;
                            state      <= S_IFG;
                            count      <= 4'd0;
                        end else begin
                            s_axis_tready <= 1'b1;
                        end
                    end else if (s_axis_tvalid) begin
                        stall_cnt      <= 4'd0;
                        gmii_txd       <= s_axis_tdata;
                        crc_data_valid <= 1'b1;
                        crc_data_in    <= s_axis_tdata;
                        crc_accum      <= crc_step_byte(crc_accum, s_axis_tdata);
                        data_cnt       <= data_cnt + 14'd1;
                        if (s_axis_tlast) begin
                            crc_saved     <= ~crc_step_byte(crc_accum, s_axis_tdata);
                            frame_ended   <= 1'b1;
                            s_axis_tready <= 1'b0;
                        end else if (data_cnt >= MAX_FRAME - 1) begin
                            gmii_tx_er     <= 1'b1;
                            state          <= S_IFG;
                            count          <= 4'd0;
                            s_axis_tready  <= 1'b0;
                        end else begin
                            s_axis_tready <= 1'b1;
                        end
                    end else begin
                        gmii_txd   <= 8'h00;
                        gmii_tx_er <= 1'b1;
                        stall_cnt  <= stall_cnt + 4'd1;
                        if (stall_cnt >= 4'd7) begin
                            state <= S_IFG;
                            count <= 4'd0;
                        end
                    end
                end

                S_PAD: begin
                    stall_cnt      <= 4'd0;
                    gmii_txd       <= 8'h00;
                    crc_data_valid <= 1'b1;
                    crc_data_in    <= 8'h00;
                    crc_accum      <= crc_step_byte(crc_accum, 8'h00);
                    data_cnt       <= data_cnt + 14'd1;
                    if (data_cnt >= MIN_FRAME - 1) begin
                        crc_saved <= ~crc_step_byte(crc_accum, 8'h00);
                        state     <= S_CRC;
                        count     <= 4'd0;
                    end
                end

                S_CRC: begin
                    stall_cnt <= 4'd0;
                    count <= count + 4'd1;
                    case (count)
                        4'd0: gmii_txd <= crc_saved[7:0];
                        4'd1: gmii_txd <= crc_saved[15:8];
                        4'd2: gmii_txd <= crc_saved[23:16];
                        4'd3: begin
                            gmii_txd <= crc_saved[31:24];
                            state    <= S_IFG;
                            count    <= 4'd0;
                        end
                        default: ;
                    endcase
                end

                S_IFG: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'd0;
                    stall_cnt  <= 4'd0;
                    count      <= count + 4'd1;
                    if (count >= IFG_BYTES - 1)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
