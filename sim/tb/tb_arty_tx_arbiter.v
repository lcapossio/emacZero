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

    // ---- Frame-integrity scenario (auto sources + scoreboard) ----
    // Each auto source sends 4-byte frames tagged {tag, index}: blast 0x6_,
    // ARP 0xA_, ICMP 0xC_. Every output frame must be 4 bytes from one
    // source, in order.
    reg        auto_mode = 1'b0;
    reg        blast_en  = 1'b0;
    reg        arp_go    = 1'b0;
    reg        icmp_go   = 1'b0;
    reg        bp_mode   = 1'b0;   // pseudo-random downstream backpressure
    reg [1:0]  bidx, aidx, iidx;
    reg [15:0] lfsr = 16'hACE1;
    integer    sb_pos = 0;
    reg [3:0]  sb_tag;
    integer    sb_err = 0;
    integer    n_blast = 0, n_arp = 0, n_icmp = 0;

    always @(posedge clk) if (auto_mode) begin
        // blast: back to back while enabled; a started frame is finished
        if (!blast_tvalid) begin
            if (blast_en) begin
                blast_tvalid <= 1'b1; blast_tdata <= 8'h60; blast_tlast <= 1'b0; bidx <= 2'd0;
            end
        end else if (blast_tready) begin
            if (bidx == 2'd3) begin
                blast_tvalid <= blast_en; blast_tdata <= 8'h60; blast_tlast <= 1'b0; bidx <= 2'd0;
            end else begin
                bidx <= bidx + 2'd1; blast_tdata <= {4'h6, 2'b00, bidx + 2'd1};
                blast_tlast <= (bidx == 2'd2);
            end
        end
        // ARP: one frame per arp_go pulse
        if (!arp_tvalid) begin
            if (arp_go) begin
                arp_tvalid <= 1'b1; arp_tdata <= 8'hA0; arp_tlast <= 1'b0; aidx <= 2'd0;
            end
        end else if (arp_tready) begin
            if (aidx == 2'd3) begin
                arp_tvalid <= 1'b0; arp_tlast <= 1'b0;
            end else begin
                aidx <= aidx + 2'd1; arp_tdata <= {4'hA, 2'b00, aidx + 2'd1};
                arp_tlast <= (aidx == 2'd2);
            end
        end
        // ICMP: one frame per icmp_go pulse
        if (!icmp_tvalid) begin
            if (icmp_go) begin
                icmp_tvalid <= 1'b1; icmp_tdata <= 8'hC0; icmp_tlast <= 1'b0; iidx <= 2'd0;
            end
        end else if (icmp_tready) begin
            if (iidx == 2'd3) begin
                icmp_tvalid <= 1'b0; icmp_tlast <= 1'b0;
            end else begin
                iidx <= iidx + 2'd1; icmp_tdata <= {4'hC, 2'b00, iidx + 2'd1};
                icmp_tlast <= (iidx == 2'd2);
            end
        end
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        m_axis_tready <= bp_mode ? lfsr[0] : 1'b1;
    end

    always @(posedge clk) if (auto_mode && m_axis_tvalid && m_axis_tready) begin
        if (sb_pos == 0) sb_tag = m_axis_tdata[7:4];
        if (m_axis_tdata[7:4] != sb_tag || m_axis_tdata[3:0] != sb_pos[3:0] ||
            m_axis_tlast != (sb_pos == 3)) begin
            if (sb_err < 4)
                $display("  mixed frame: byte %0d = %02h (frame tag %h, tlast %b)",
                         sb_pos, m_axis_tdata, sb_tag, m_axis_tlast);
            sb_err = sb_err + 1;
        end
        if (m_axis_tlast) begin
            if (sb_tag == 4'h6) n_blast = n_blast + 1;
            if (sb_tag == 4'hA) n_arp   = n_arp + 1;
            if (sb_tag == 4'hC) n_icmp  = n_icmp + 1;
            sb_pos = 0;
        end else
            sb_pos = sb_pos + 1;
    end

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
        #1;
        check("owner held until tlast", udp_tready && !arp_tready);
        @(posedge clk);
        #1;
        check("udp tlast byte out", m_axis_tdata == 8'h52 && m_axis_tlast);
        check("arp next after udp tlast", arp_tready && !udp_tready);
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

        // Two blast frames with interval=1 start the service holdoff: blast
        // is refused for BLAST_SERVICE_IDLE_CYCLES (3) cycles so another
        // source can get a slot, then it is taken again.
        clear_inputs;
        blast_tvalid = 1'b1; blast_tlast = 1'b1; blast_tdata = 8'h61;
        #1;
        check("first blast frame taken", blast_tready);
        @(posedge clk); #1;
        blast_tdata = 8'h62;
        check("second blast frame taken", blast_tready);
        @(posedge clk); #1;
        blast_tdata = 8'h63;
        check("blast service holdoff suppresses blast", !blast_tready);
        repeat (2) begin @(posedge clk); #1; end
        check("holdoff still suppressing", !blast_tready);
        @(posedge clk); #1;
        check("blast resumes after holdoff", blast_tready);
        @(posedge clk); #1;
        clear_inputs;
        @(posedge clk); #1;

        // Frame integrity: a source's next frame must not lose its first
        // byte at the handover, nor have it land in front of another
        // source's frame (ARP / ICMP requested at every phase of back-to-back
        // blast frames, without and with downstream backpressure).
        repeat (8) begin @(posedge clk); #1; end
        auto_mode = 1'b1;
        repeat (2) begin : integ_pass
            integer ph;
            blast_en = 1'b1;
            for (ph = 0; ph < 24; ph = ph + 1) begin
                repeat (ph + 3) @(posedge clk);
                #1;
                if (ph[0]) icmp_go = 1'b1; else arp_go = 1'b1;
                @(posedge clk); #1;
                arp_go = 1'b0; icmp_go = 1'b0;
                repeat (40) @(posedge clk);
                #1;
            end
            blast_en = 1'b0;
            repeat (60) @(posedge clk);
            #1;
            bp_mode = 1'b1;
        end
        bp_mode = 1'b0;
        repeat (4) @(posedge clk);
        #1;
        auto_mode = 1'b0;
        m_axis_tready = 1'b1;
        $display("  integrity: %0d blast, %0d ARP, %0d ICMP frames, %0d bad bytes",
                 n_blast, n_arp, n_icmp, sb_err);
        check("no mixed or cut frames at handover", sb_err == 0);
        check("all ARP frames sent", n_arp == 24);
        check("all ICMP frames sent", n_icmp == 24);
        check("blast frames flowed", n_blast > 50);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
