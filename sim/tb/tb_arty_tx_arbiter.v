// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_arty_tx_arbiter.v - Unit test for the Arty 6-input AXIS arbiter
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_arty_tx_arbiter;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg arp_tx_active;

    reg [7:0] seq_tdata, arp_tdata, icmp_tdata, stats_tdata, udp_tdata, blast_tdata;
    reg seq_tvalid, arp_tvalid, icmp_tvalid, stats_tvalid, udp_tvalid, blast_tvalid;
    reg seq_tlast, arp_tlast, icmp_tlast, stats_tlast, udp_tlast, blast_tlast;
    wire seq_tready, arp_tready, icmp_tready, stats_tready, udp_tready, blast_tready;

    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    reg        m_axis_tready;
    wire       m_axis_tlast;

    arty_tx_arbiter #(
        .BLAST_SERVICE_INTERVAL(8'd1),
        .BLAST_SERVICE_IDLE_CYCLES(12'd3)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .arp_tx_active (arp_tx_active),
        .seq_tdata     (seq_tdata),
        .seq_tvalid    (seq_tvalid),
        .seq_tready    (seq_tready),
        .seq_tlast     (seq_tlast),
        .arp_tdata     (arp_tdata),
        .arp_tvalid    (arp_tvalid),
        .arp_tready    (arp_tready),
        .arp_tlast     (arp_tlast),
        .icmp_tdata    (icmp_tdata),
        .icmp_tvalid   (icmp_tvalid),
        .icmp_tready   (icmp_tready),
        .icmp_tlast    (icmp_tlast),
        .stats_tdata   (stats_tdata),
        .stats_tvalid  (stats_tvalid),
        .stats_tready  (stats_tready),
        .stats_tlast   (stats_tlast),
        .udp_tdata     (udp_tdata),
        .udp_tvalid    (udp_tvalid),
        .udp_tready    (udp_tready),
        .udp_tlast     (udp_tlast),
        .blast_tdata   (blast_tdata),
        .blast_tvalid  (blast_tvalid),
        .blast_tready  (blast_tready),
        .blast_tlast   (blast_tlast),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input [255:0] name;
        input cond;
        begin
            if (cond) begin
                $display("PASS: %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s", name);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task clear_inputs;
        begin
            seq_tvalid = 1'b0; arp_tvalid = 1'b0; icmp_tvalid = 1'b0;
            stats_tvalid = 1'b0; udp_tvalid = 1'b0; blast_tvalid = 1'b0;
            seq_tlast = 1'b0; arp_tlast = 1'b0; icmp_tlast = 1'b0;
            stats_tlast = 1'b0; udp_tlast = 1'b0; blast_tlast = 1'b0;
        end
    endtask

    task drive_one;
        input integer port;
        input [7:0] data;
        begin
            clear_inputs;
            case (port)
                0: begin seq_tdata = data; seq_tvalid = 1'b1; seq_tlast = 1'b1; end
                1: begin arp_tdata = data; arp_tvalid = 1'b1; arp_tlast = 1'b1; end
                2: begin icmp_tdata = data; icmp_tvalid = 1'b1; icmp_tlast = 1'b1; end
                3: begin stats_tdata = data; stats_tvalid = 1'b1; stats_tlast = 1'b1; end
                4: begin udp_tdata = data; udp_tvalid = 1'b1; udp_tlast = 1'b1; end
                5: begin blast_tdata = data; blast_tvalid = 1'b1; blast_tlast = 1'b1; end
                default: ;
            endcase
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;
            clear_inputs;
        end
    endtask

    initial begin
        $dumpfile("tb_arty_tx_arbiter.vcd");
        $dumpvars(0, tb_arty_tx_arbiter);

        arp_tx_active = 1'b0;
        m_axis_tready = 1'b1;
        seq_tdata = 8'h10; arp_tdata = 8'h20; icmp_tdata = 8'h30;
        stats_tdata = 8'h40; udp_tdata = 8'h50; blast_tdata = 8'h60;
        clear_inputs;

        #50;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Overlapping non-sequencer requests choose ARP first.
        arp_tvalid = 1'b1; arp_tlast = 1'b1; arp_tdata = 8'ha1;
        icmp_tvalid = 1'b1; icmp_tlast = 1'b1; icmp_tdata = 8'hc1;
        udp_tvalid = 1'b1; udp_tlast = 1'b1; udp_tdata = 8'he1;
        @(posedge clk);
        #1;
        check("arp priority over icmp/udp", m_axis_tvalid && m_axis_tdata == 8'ha1);
        clear_inputs;
        @(posedge clk);
        #1;

        // Sequencer only owns highest priority while arp_tx_active is high.
        arp_tx_active = 1'b1;
        seq_tvalid = 1'b1; seq_tlast = 1'b1; seq_tdata = 8'h11;
        arp_tvalid = 1'b1; arp_tlast = 1'b1; arp_tdata = 8'ha2;
        @(posedge clk);
        #1;
        check("seq priority while active", m_axis_tvalid && m_axis_tdata == 8'h11);
        clear_inputs;
        arp_tx_active = 1'b0;
        @(posedge clk);
        #1;

        // Owner is held for an in-flight frame even if a higher-priority source appears.
        udp_tvalid = 1'b1; udp_tlast = 1'b0; udp_tdata = 8'h51;
        @(posedge clk);
        #1;
        check("udp first byte accepted", udp_tready && m_axis_tdata == 8'h51);
        arp_tvalid = 1'b1; arp_tlast = 1'b1; arp_tdata = 8'ha3;
        udp_tdata = 8'h52; udp_tlast = 1'b1;
        @(posedge clk);
        #1;
        check("owner held until tlast", udp_tready && !arp_tready && m_axis_tdata == 8'h52);
        clear_inputs;
        @(posedge clk);
        #1;

        // Backpressure holds output and source ready drops.
        m_axis_tready = 1'b0;
        icmp_tvalid = 1'b1; icmp_tlast = 1'b1; icmp_tdata = 8'h33;
        @(posedge clk);
        #1;
        check("slice fills under backpressure", m_axis_tvalid && m_axis_tdata == 8'h33);
        icmp_tdata = 8'h34;
        @(posedge clk);
        #1;
        check("ready drops when slice full", !icmp_tready && m_axis_tdata == 8'h33);
        m_axis_tready = 1'b1;
        clear_inputs;
        @(posedge clk);
        #1;

        // After two blast frames with interval=1, blast is held off long enough
        // for a lower traffic source slot to be visible.
        drive_one(5, 8'h61);
        drive_one(5, 8'h62);
        blast_tvalid = 1'b1; blast_tlast = 1'b1; blast_tdata = 8'h63;
        repeat (2) begin @(posedge clk); #1; end
        check("blast service holdoff suppresses blast", !blast_tready);
        clear_inputs;
        repeat (4) begin @(posedge clk); #1; end
        blast_tvalid = 1'b1; blast_tlast = 1'b1; blast_tdata = 8'h64;
        @(posedge clk);
        #1;
        check("blast resumes after holdoff", blast_tready);
        clear_inputs;

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
