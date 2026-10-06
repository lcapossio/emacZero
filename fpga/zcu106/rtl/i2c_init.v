// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// i2c_init.v - Power-up I2C register writer
// Plays a fixed list of I2C write transactions out of a ROM, then asserts
// done. Each ROM entry is one transaction of 2 or 3 bytes (address+W byte
// first), e.g. a mux channel select or a {reg, value} register write. Any
// NACK aborts the pass; the whole list is retried after RETRY_DELAY with the
// `alt` ROM input toggled, which lets the ROM try a second device address.
//
// The ROM is the rom_entry() function in zcu106_si5328_rom.vh, which also
// defines ROM_LEN. Entry format: {last[1:0], b0, b1, b2}, where `last` is the
// index of the final byte (1 = two-byte write, 2 = three-byte write).
//
// SCL/SDA are open drain: *_t = 1 releases the line (pull-up), 0 drives low.
// No clock stretching (the Si5328 and TCA9548A never stretch).
// Verilog 2001
// =============================================================================

module i2c_init #(
    parameter CLK_HZ       = 50_000_000,
    parameter I2C_HZ       = 100_000,
    parameter START_DELAY  = 50_000_000 / 10,  // cycles before the first pass
    parameter RETRY_DELAY  = 50_000_000 / 10,  // cycles between failed passes
    parameter DONE_DELAY   = 50_000_000 / 2    // cycles after the last write
)(
    input  wire clk,
    input  wire rst_n,

    output reg  scl_t,
    output reg  sda_t,
    input  wire sda_i,

    output reg  done,          // list written and DONE_DELAY elapsed
    output reg  busy,
    output reg  [7:0] nack_count
);

`include "zcu106_si5328_rom.vh"

    // SDA is sampled in the middle of SCL high, a quarter bit after the rise,
    // so two synchronizer cycles of latency are harmless.
    (* ASYNC_REG = "TRUE" *) reg [1:0] sda_sync;
    always @(posedge clk) sda_sync <= {sda_sync[0], sda_i};
    wire sda_s = sda_sync[1];

    // Quarter-bit tick: SCL low/high phases are each two quarters.
    localparam integer QTR = CLK_HZ / (I2C_HZ * 4);
    localparam integer DLY_W = 32;

    reg [15:0] qcnt;
    wire       qtick = (qcnt == 16'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     qcnt <= QTR - 1;
        else if (qtick) qcnt <= QTR - 1;
        else            qcnt <= qcnt - 16'd1;
    end

    localparam [3:0] S_WAIT  = 4'd0,
                     S_LOAD  = 4'd1,
                     S_START = 4'd2,
                     S_BIT   = 4'd3,
                     S_ACK   = 4'd4,
                     S_STOP  = 4'd5,
                     S_NEXT  = 4'd6,
                     S_DONE  = 4'd7;

    reg [3:0]        state;
    reg [DLY_W-1:0]  delay;
    reg [15:0]       idx;          // ROM entry
    reg [25:0]       entry;        // {last[1:0], b0, b1, b2}
    reg [1:0]        byte_i;       // byte within the transaction
    reg [7:0]        shreg;
    reg [2:0]        bit_i;
    reg [1:0]        phase;        // quarter within the bit
    reg              nacked;
    reg              alt;          // toggles on every retry

    wire [1:0] entry_last = entry[25:24];
    wire [7:0] entry_byte = (byte_i == 2'd0) ? entry[23:16] :
                            (byte_i == 2'd1) ? entry[15:8]  : entry[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_WAIT;
            delay      <= START_DELAY;
            idx        <= 16'd0;
            entry      <= 26'd0;
            byte_i     <= 2'd0;
            shreg      <= 8'd0;
            bit_i      <= 3'd0;
            phase      <= 2'd0;
            nacked     <= 1'b0;
            alt        <= 1'b0;
            scl_t      <= 1'b1;
            sda_t      <= 1'b1;
            done       <= 1'b0;
            busy       <= 1'b0;
            nack_count <= 8'd0;
        end else begin
            case (state)
            S_WAIT: begin
                scl_t <= 1'b1;
                sda_t <= 1'b1;
                if (delay != 0) delay <= delay - 1'b1;
                else begin
                    idx    <= 16'd0;
                    nacked <= 1'b0;
                    busy   <= 1'b1;
                    state  <= S_LOAD;
                end
            end

            S_LOAD: begin
                entry  <= rom_entry(idx, alt);
                byte_i <= 2'd0;
                phase  <= 2'd0;
                state  <= S_START;
            end

            // START: SDA falls while SCL is high, then SCL falls.
            S_START: if (qtick) begin
                phase <= phase + 2'd1;
                case (phase)
                    2'd0: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                    2'd1: sda_t <= 1'b0;
                    2'd2: scl_t <= 1'b0;
                    2'd3: begin
                        shreg <= entry_byte;
                        bit_i <= 3'd7;
                        state <= S_BIT;
                    end
                endcase
            end

            // Data bit: set SDA with SCL low, pulse SCL high for two quarters.
            S_BIT: if (qtick) begin
                phase <= phase + 2'd1;
                case (phase)
                    2'd0: sda_t <= shreg[7];
                    2'd1: scl_t <= 1'b1;
                    2'd2: ;
                    2'd3: begin
                        scl_t <= 1'b0;
                        shreg <= {shreg[6:0], 1'b0};
                        if (bit_i == 3'd0) state <= S_ACK;
                        else               bit_i <= bit_i - 3'd1;
                    end
                endcase
            end

            // ACK: release SDA, sample it mid SCL-high.
            S_ACK: if (qtick) begin
                phase <= phase + 2'd1;
                case (phase)
                    2'd0: sda_t <= 1'b1;
                    2'd1: scl_t <= 1'b1;
                    2'd2: if (sda_s) nacked <= 1'b1;
                    2'd3: begin
                        scl_t <= 1'b0;
                        if (nacked || byte_i == entry_last) begin
                            state <= S_STOP;
                        end else begin
                            byte_i <= byte_i + 2'd1;
                            state  <= S_NEXT;
                        end
                    end
                endcase
            end

            S_NEXT: begin
                shreg <= entry_byte;
                bit_i <= 3'd7;
                state <= S_BIT;
            end

            // STOP: SDA rises while SCL is high.
            S_STOP: if (qtick) begin
                phase <= phase + 2'd1;
                case (phase)
                    2'd0: sda_t <= 1'b0;
                    2'd1: scl_t <= 1'b1;
                    2'd2: sda_t <= 1'b1;
                    2'd3: begin
                        if (nacked) begin
                            nack_count <= (nack_count == 8'hFF) ? 8'hFF : nack_count + 8'd1;
                            alt   <= ~alt;
                            busy  <= 1'b0;
                            delay <= RETRY_DELAY;
                            state <= S_WAIT;
                        end else if (idx == ROM_LEN - 1) begin
                            busy  <= 1'b0;
                            delay <= DONE_DELAY;
                            state <= S_DONE;
                        end else begin
                            idx   <= idx + 16'd1;
                            state <= S_LOAD;
                        end
                    end
                endcase
            end

            S_DONE: begin
                if (delay != 0) delay <= delay - 1'b1;
                else            done  <= 1'b1;
            end

            default: state <= S_WAIT;
            endcase
        end
    end

endmodule
