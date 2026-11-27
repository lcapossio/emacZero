// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axil_cmd_master.v - one AXI4-Lite access per command toggle, for driving a
// CSR block from a debug port (the ZCU106 10G design's EIO)
//
// Set write / addr / wdata, then flip go. go is synchronized here, so the
// other fields may come from another clock domain as long as they are stable
// before go flips. When the access is done, ack equals go again and, for a
// read, rdata holds the value (until the next read).
// Verilog 2001
// =============================================================================

module axil_cmd_master (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        go,              // toggle: start an access
    input  wire        write,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg         ack,             // == go when the access is done
    output reg  [31:0] rdata,

    output wire [7:0]  m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [7:0]  m_axi_araddr,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);

    (* ASYNC_REG = "TRUE" *) reg [2:0] go_s;

    localparam S_IDLE = 2'd0, S_WR = 2'd1, S_RD = 2'd2;
    reg [1:0]  st;
    reg [7:0]  a_q;
    reg [31:0] d_q;

    assign m_axi_awaddr = a_q;
    assign m_axi_araddr = a_q;
    assign m_axi_wdata  = d_q;
    assign m_axi_wstrb  = 4'hF;
    assign m_axi_bready = (st == S_WR);
    assign m_axi_rready = (st == S_RD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_s          <= 3'b000;
            st            <= S_IDLE;
            a_q           <= 8'd0;
            d_q           <= 32'd0;
            ack           <= 1'b0;
            rdata         <= 32'd0;
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_arvalid <= 1'b0;
        end else begin
            go_s <= {go_s[1:0], go};
            case (st)
                S_IDLE: if (go_s[2] != ack) begin
                    a_q <= addr;
                    d_q <= wdata;
                    if (write) begin
                        m_axi_awvalid <= 1'b1;
                        m_axi_wvalid  <= 1'b1;
                        st            <= S_WR;
                    end else begin
                        m_axi_arvalid <= 1'b1;
                        st            <= S_RD;
                    end
                end
                S_WR: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
                    if (m_axi_bvalid) begin
                        ack <= go_s[2];
                        st  <= S_IDLE;
                    end
                end
                default: begin      // S_RD
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    if (m_axi_rvalid) begin
                        rdata <= m_axi_rdata;
                        ack   <= go_s[2];
                        st    <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
