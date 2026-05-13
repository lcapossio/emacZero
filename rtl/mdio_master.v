// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio � bard0 design
// =============================================================================
// mdio_master.v — MDIO master supporting clause-22 and clause-45
// Verilog 2001
// -----------------------------------------------------------------------------
// Clause-22 (cmd_c45_en=0):
//   ST=01, OP={10=read, 01=write}, PRTAD[4:0], REGAD[4:0], TA, DATA[15:0]
//   cmd_reg holds REGAD; cmd_wdata holds DATA on writes; rdata returns DATA.
//
// Clause-45 (cmd_c45_en=1):
//   ST=00, OP=cmd_c45_op[1:0], PRTAD[4:0], DEVAD[4:0], TA, DATA[15:0]
//   OP encoding (IEEE 802.3 clause 45.2.4):
//     00 = ADDRESS  (cmd_wdata[15:0] is the register-address payload)
//     01 = WRITE    (cmd_wdata[15:0] is the data payload)
//     10 = READ-INC (post-increment internal address; data returns on rdata)
//     11 = READ     (data returns on rdata)
//   The two-step sequence is driven by software: issue an ADDRESS frame to
//   latch the 16-bit register address inside the PHY, then issue a READ or
//   WRITE frame using the same DEVAD.
// =============================================================================

module mdio_master (
    input  wire        clk,        // system clock
    input  wire        rst_n,

    // MDIO pins
    output reg         mdc,
    input  wire        mdio_i,     // MDIO input (directly from pad)
    output reg         mdio_o,     // MDIO output
    output reg         mdio_oe,    // output enable (active high)

    // Command interface
    input  wire        cmd_valid,    // pulse to start operation
    input  wire        cmd_write,    // C22 only: 0=read, 1=write
    input  wire [4:0]  cmd_phy,      // PHY address (PRTAD)
    input  wire [4:0]  cmd_reg,      // C22: REGAD; C45: DEVAD
    input  wire [15:0] cmd_wdata,    // C22 write data, or C45 ADDRESS / WRITE payload
    input  wire        cmd_c45_en,   // 1 = clause-45 framing, 0 = clause-22
    input  wire [1:0]  cmd_c45_op,   // C45 OP: 00=ADDR 01=WRITE 10=READ-INC 11=READ
    output reg  [15:0] cmd_rdata,    // read data (C22 read or C45 READ/READ-INC)
    output reg         cmd_done,     // pulse when operation complete

    // Debug: count mdio_i=0 at exact S_DATA read sampling instants
    output reg  [4:0]  dbg_rd_low_cnt,  // how many bits were 0 during read
    output reg  [15:0] dbg_rd_raw       // raw captured shift_reg after read
);

    // MDC divider: clk/100 = 1 MHz MDC
    reg [6:0] mdc_div;
    wire      mdc_rising = (mdc_div == 7'd49);
    wire      mdc_falling = (mdc_div == 7'd99);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdc_div <= 0;
            mdc <= 0;
        end else begin
            if (mdc_div >= 7'd99) mdc_div <= 0;
            else mdc_div <= mdc_div + 1;
            if (mdc_div == 7'd49) mdc <= 1;
            else if (mdc_div == 7'd99) mdc <= 0;
        end
    end

    // State machine — drives data on MDC falling edge (setup for PHY)
    // PHY samples on rising edge; master samples read data on rising edge
    localparam [3:0]
        S_IDLE  = 4'd0,
        S_PRE   = 4'd1,
        S_ST1   = 4'd2,
        S_ST2   = 4'd3,
        S_OP1   = 4'd4,
        S_OP2   = 4'd5,
        S_PHY   = 4'd6,
        S_REG   = 4'd7,
        S_TA1   = 4'd8,
        S_TA2   = 4'd9,
        S_DATA  = 4'd10,
        S_DONE  = 4'd11;

    reg [3:0]  state;
    reg [5:0]  bit_cnt;
    reg        is_write;     // C22 write, or C45 op that drives data on TA/DATA
    reg [4:0]  phy_addr;
    reg [4:0]  reg_addr;     // C22 REGAD or C45 DEVAD
    reg [15:0] shift_reg;
    reg        c45_en;
    reg [1:0]  c45_op;       // latched C45 OP code

    // In C45 mode, ADDRESS (00) and WRITE (01) drive the bus on TA/DATA;
    // READ (11) and READ-INC (10) tri-state the bus the same way as C22 reads.
    wire drive_data = c45_en ? (c45_op == 2'b00 || c45_op == 2'b01) : is_write;

    // Capture MDIO input on MDC rising edge per IEEE 802.3 clause 22.3.4.
    // PHY changes data on falling edge; we sample on rising edge.
    reg        mdio_i_sampled;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mdio_i_sampled <= 1'b1;
        else if (mdc_rising)
            mdio_i_sampled <= mdio_i;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            bit_cnt  <= 0;
            mdio_o   <= 1;
            mdio_oe  <= 0;
            cmd_rdata <= 0;
            cmd_done <= 0;
            is_write <= 0;
            phy_addr <= 0;
            reg_addr <= 0;
            shift_reg <= 0;
            c45_en   <= 0;
            c45_op   <= 0;
            dbg_rd_low_cnt <= 0;
            dbg_rd_raw     <= 0;
        end else begin
            cmd_done <= 1'b0;

            if (state == S_IDLE) begin
                if (cmd_valid) begin
                    is_write  <= cmd_write;
                    phy_addr  <= cmd_phy;
                    reg_addr  <= cmd_reg;
                    shift_reg <= cmd_wdata;
                    c45_en    <= cmd_c45_en;
                    c45_op    <= cmd_c45_op;
                    state     <= S_PRE;
                    bit_cnt   <= 0;
                    mdio_oe   <= 1;
                    mdio_o    <= 1;
                end
            end else if (mdc_falling) begin
                // Change data on falling edge (setup time before rising edge)
                case (state)
                    S_PRE: begin
                        mdio_o <= 1;
                        mdio_oe <= 1;
                        bit_cnt <= bit_cnt + 1;
                        if (bit_cnt >= 31) begin
                            state <= S_ST1;
                        end
                    end

                    // ST: C22 = 01, C45 = 00
                    S_ST1: begin mdio_o <= 0;             state <= S_ST2; end
                    S_ST2: begin mdio_o <= c45_en ? 0 : 1; state <= S_OP1; end

                    // OP: C22 read=10 / write=01; C45 = c45_op[1:0]
                    S_OP1: begin
                        mdio_o <= c45_en ? c45_op[1] : (is_write ? 0 : 1);
                        state  <= S_OP2;
                    end
                    S_OP2: begin
                        mdio_o  <= c45_en ? c45_op[0] : (is_write ? 1 : 0);
                        state   <= S_PHY;
                        bit_cnt <= 0;
                    end

                    S_PHY: begin
                        mdio_o <= phy_addr[4 - bit_cnt];
                        bit_cnt <= bit_cnt + 1;
                        if (bit_cnt >= 4) begin state <= S_REG; bit_cnt <= 0; end
                    end

                    S_REG: begin
                        mdio_o <= reg_addr[4 - bit_cnt];
                        bit_cnt <= bit_cnt + 1;
                        if (bit_cnt >= 4) begin state <= S_TA1; end
                    end

                    S_TA1: begin
                        if (drive_data) begin
                            mdio_o <= 1; // master-driven TA: 10
                        end else begin
                            mdio_oe <= 0; // read: release bus, PHY drives 0
                        end
                        state <= S_TA2;
                    end

                    S_TA2: begin
                        if (drive_data) begin
                            mdio_o <= 0;
                        end
                        // For reads: PHY drives 0 here; D[15] only becomes stable on the
                        // NEXT MDC falling edge.  S_DATA runs 17 iterations for reads
                        // (bit_cnt 0..16): iteration 0 captures TA[2]=0 into shift_reg[0],
                        // which is discarded by the final {shift_reg[14:0], mdio_i_sampled}.
                        // Iterations 1..16 then correctly capture D[15:0].
                        state   <= S_DATA;
                        bit_cnt <= 0;
                    end

                    S_DATA: begin
                        if (drive_data) begin
                            mdio_o <= shift_reg[15];
                            shift_reg <= {shift_reg[14:0], 1'b0};
                        end else begin
                            // Read: use rising-edge-captured MDIO sample
                            shift_reg <= {shift_reg[14:0], mdio_i_sampled};
                            if (!mdio_i_sampled)
                                dbg_rd_low_cnt <= dbg_rd_low_cnt + 5'd1;
                        end
                        bit_cnt <= bit_cnt + 1;
                        // Reads run 17 iterations (bit_cnt 0..16): iteration 0 captures
                        // TA[2]=0 which ends up at shift_reg[15] and is discarded by
                        // {shift_reg[14:0], mdio_i_sampled}; iterations 1..16 capture
                        // D[15:0].  Writes run 16 iterations (bit_cnt 0..15) unchanged.
                        if ((!drive_data && bit_cnt >= 16) || (drive_data && bit_cnt >= 15)) begin
                            if (!drive_data) begin
                                cmd_rdata  <= {shift_reg[14:0], mdio_i_sampled};
                                dbg_rd_raw <= {shift_reg[14:0], mdio_i_sampled};
                            end
                            state <= S_DONE;
                        end
                    end

                    S_DONE: begin
                        mdio_oe <= 0;
                        cmd_done <= 1;
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
