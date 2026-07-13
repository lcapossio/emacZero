// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_axil_arb2.v - Verifies the 2:1 AXI4-Lite arbiter (axil_arb2) against a
// behavioral regfile slave with two concurrently-active masters.
// =============================================================================
`timescale 1ns/1ps

module tb_axil_arb2;
    localparam AW = 8, DW = 32;

    reg aclk = 0; always #5 aclk = ~aclk;   // 100 MHz
    reg aresetn = 0;

    // ---- m0 ----
    reg [AW-1:0] m0_awaddr; reg m0_awvalid; wire m0_awready;
    reg [DW-1:0] m0_wdata;  reg [3:0] m0_wstrb; reg m0_wvalid; wire m0_wready;
    wire [1:0] m0_bresp; wire m0_bvalid; reg m0_bready;
    reg [AW-1:0] m0_araddr; reg m0_arvalid; wire m0_arready;
    wire [DW-1:0] m0_rdata; wire [1:0] m0_rresp; wire m0_rvalid; reg m0_rready;
    // ---- m1 ----
    reg [AW-1:0] m1_awaddr; reg m1_awvalid; wire m1_awready;
    reg [DW-1:0] m1_wdata;  reg [3:0] m1_wstrb; reg m1_wvalid; wire m1_wready;
    wire [1:0] m1_bresp; wire m1_bvalid; reg m1_bready;
    reg [AW-1:0] m1_araddr; reg m1_arvalid; wire m1_arready;
    wire [DW-1:0] m1_rdata; wire [1:0] m1_rresp; wire m1_rvalid; reg m1_rready;
    // ---- slave ----
    wire [AW-1:0] s_awaddr; wire s_awvalid; wire s_awready;
    wire [DW-1:0] s_wdata;  wire [3:0] s_wstrb; wire s_wvalid; wire s_wready;
    wire [1:0] s_bresp; wire s_bvalid; wire s_bready;
    wire [AW-1:0] s_araddr; wire s_arvalid; wire s_arready;
    wire [DW-1:0] s_rdata; wire [1:0] s_rresp; wire s_rvalid; wire s_rready;

    axil_arb2 #(.AW(AW), .DW(DW)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .m0_awaddr(m0_awaddr), .m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
        .m0_wdata(m0_wdata), .m0_wstrb(m0_wstrb), .m0_wvalid(m0_wvalid), .m0_wready(m0_wready),
        .m0_bresp(m0_bresp), .m0_bvalid(m0_bvalid), .m0_bready(m0_bready),
        .m0_araddr(m0_araddr), .m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
        .m0_rdata(m0_rdata), .m0_rresp(m0_rresp), .m0_rvalid(m0_rvalid), .m0_rready(m0_rready),
        .m1_awaddr(m1_awaddr), .m1_awvalid(m1_awvalid), .m1_awready(m1_awready),
        .m1_wdata(m1_wdata), .m1_wstrb(m1_wstrb), .m1_wvalid(m1_wvalid), .m1_wready(m1_wready),
        .m1_bresp(m1_bresp), .m1_bvalid(m1_bvalid), .m1_bready(m1_bready),
        .m1_araddr(m1_araddr), .m1_arvalid(m1_arvalid), .m1_arready(m1_arready),
        .m1_rdata(m1_rdata), .m1_rresp(m1_rresp), .m1_rvalid(m1_rvalid), .m1_rready(m1_rready),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid), .s_rready(s_rready)
    );

    // ---- Behavioral AXI-Lite regfile slave (64 x 32), 1-cycle ready latency ----
    reg [DW-1:0] mem [0:63];
    reg [AW-1:0] aw_a; reg aw_l, w_l; reg [DW-1:0] w_d;
    reg s_awready_r, s_wready_r, s_bvalid_r;
    reg s_arready_r, s_rvalid_r; reg [DW-1:0] s_rdata_r;
    assign s_awready = s_awready_r; assign s_wready = s_wready_r;
    assign s_bvalid = s_bvalid_r; assign s_bresp = 2'b00;
    assign s_arready = s_arready_r; assign s_rvalid = s_rvalid_r;
    assign s_rdata = s_rdata_r; assign s_rresp = 2'b00;

    integer k;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            aw_l <= 0; w_l <= 0; s_awready_r <= 1; s_wready_r <= 1; s_bvalid_r <= 0;
            s_arready_r <= 1; s_rvalid_r <= 0;
            for (k = 0; k < 64; k = k + 1) mem[k] <= 32'd0;
        end else begin
            // write addr/data capture
            if (s_awvalid && s_awready_r) begin aw_a <= s_awaddr; aw_l <= 1; s_awready_r <= 0; end
            if (s_wvalid && s_wready_r)  begin w_d  <= s_wdata;  w_l <= 1; s_wready_r <= 0; end
            if (aw_l && w_l && !s_bvalid_r) begin
                mem[aw_a[7:2]] <= w_d;
                s_bvalid_r <= 1; aw_l <= 0; w_l <= 0;
            end
            if (s_bvalid_r && s_bready) begin s_bvalid_r <= 0; s_awready_r <= 1; s_wready_r <= 1; end
            // read
            if (s_arvalid && s_arready_r && !s_rvalid_r) begin
                s_rdata_r <= mem[s_araddr[7:2]]; s_rvalid_r <= 1; s_arready_r <= 0;
            end
            if (s_rvalid_r && s_rready) begin s_rvalid_r <= 0; s_arready_r <= 1; end
        end
    end

    // ---- Master 0 tasks ----
    task m0_write(input [AW-1:0] a, input [DW-1:0] d);
        begin
            @(negedge aclk);
            m0_awaddr=a; m0_awvalid=1; m0_wdata=d; m0_wstrb=4'hF; m0_wvalid=1; m0_bready=1;
            fork
                begin @(posedge aclk); while(!m0_awready) @(posedge aclk); @(negedge aclk) m0_awvalid=0; end
                begin @(posedge aclk); while(!m0_wready)  @(posedge aclk); @(negedge aclk) m0_wvalid=0; end
            join
            @(posedge aclk); while(!m0_bvalid) @(posedge aclk); @(negedge aclk) m0_bready=0;
        end
    endtask
    task m0_read(input [AW-1:0] a, output [DW-1:0] d);
        begin
            @(negedge aclk); m0_araddr=a; m0_arvalid=1; m0_rready=1;
            @(posedge aclk); while(!m0_arready) @(posedge aclk); @(negedge aclk) m0_arvalid=0;
            @(posedge aclk); while(!m0_rvalid) @(posedge aclk); d=m0_rdata; @(negedge aclk) m0_rready=0;
        end
    endtask
    // ---- Master 1 tasks ----
    task m1_write(input [AW-1:0] a, input [DW-1:0] d);
        begin
            @(negedge aclk);
            m1_awaddr=a; m1_awvalid=1; m1_wdata=d; m1_wstrb=4'hF; m1_wvalid=1; m1_bready=1;
            fork
                begin @(posedge aclk); while(!m1_awready) @(posedge aclk); @(negedge aclk) m1_awvalid=0; end
                begin @(posedge aclk); while(!m1_wready)  @(posedge aclk); @(negedge aclk) m1_wvalid=0; end
            join
            @(posedge aclk); while(!m1_bvalid) @(posedge aclk); @(negedge aclk) m1_bready=0;
        end
    endtask
    task m1_read(input [AW-1:0] a, output [DW-1:0] d);
        begin
            @(negedge aclk); m1_araddr=a; m1_arvalid=1; m1_rready=1;
            @(posedge aclk); while(!m1_arready) @(posedge aclk); @(negedge aclk) m1_arvalid=0;
            @(posedge aclk); while(!m1_rvalid) @(posedge aclk); d=m1_rdata; @(negedge aclk) m1_rready=0;
        end
    endtask

    integer fails = 0;
    integer passes = 0;
    reg [31:0] rd0, rd1;
    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin $display("FAIL %0s: got %08x exp %08x", name, got, exp); fails=fails+1; end
            else begin $display("PASS %0s = %08x", name, got); passes=passes+1; end
        end
    endtask

    initial begin
        m0_awvalid=0; m0_wvalid=0; m0_bready=0; m0_arvalid=0; m0_rready=0;
        m1_awvalid=0; m1_wvalid=0; m1_bready=0; m1_arvalid=0; m1_rready=0;
        #40 aresetn=1;
        #40;

        // Sequential sanity
        m0_write(8'h08, 32'hAAAA0000);
        m1_write(8'h14, 32'h5555FFFF);
        m0_read(8'h08, rd0); chk("m0 rd reg2", rd0, 32'hAAAA0000);
        m1_read(8'h14, rd1); chk("m1 rd reg5", rd1, 32'h5555FFFF);
        // Cross reads (each master reads the other's write)
        m0_read(8'h14, rd0); chk("m0 rd reg5", rd0, 32'h5555FFFF);
        m1_read(8'h08, rd1); chk("m1 rd reg2", rd1, 32'hAAAA0000);

        // Concurrent writes to different regs, then concurrent reads
        fork
            m0_write(8'h20, 32'h1111_2222);
            m1_write(8'h24, 32'h3333_4444);
        join
        fork
            m0_read(8'h24, rd0);
            m1_read(8'h20, rd1);
        join
        chk("concurrent m0 rd reg9", rd0, 32'h3333_4444);
        chk("concurrent m1 rd reg8", rd1, 32'h1111_2222);

        // Concurrent write (m0) + read (m1) on different channels simultaneously
        fork
            m0_write(8'h30, 32'hDEAD_BEEF);
            m1_read(8'h20, rd1);
        join
        chk("overlap m1 rd reg8", rd1, 32'h1111_2222);
        m0_read(8'h30, rd0); chk("overlap m0 wr reg12", rd0, 32'hDEAD_BEEF);

        // Hammer: many interleaved to stress arbitration
        begin: hammer integer i;
            for (i = 0; i < 8; i = i + 1) begin
                fork
                    m0_write(8'h40, 32'h0100_0000 + i);
                    m1_write(8'h44, 32'h0200_0000 + i);
                join
                fork
                    m0_read(8'h44, rd0);
                    m1_read(8'h40, rd1);
                join
                chk("hammer m0", rd0, 32'h0200_0000 + i);
                chk("hammer m1", rd1, 32'h0100_0000 + i);
            end
        end

        if (fails == 0) begin
            $display("%0d tests passed", passes);
            $display("ALL TESTS PASSED");
        end else $display("FAIL: %0d checks failed", fails);
        $finish;
    end

    initial begin #200000; $display("FAIL: timeout"); $finish; end
endmodule
