// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_blast_path.v - Integration test for UDP trigger -> blast TX path
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_blast_path;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [47:0] OUR_MAC  = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP   = 32'hC0_A8_89_C8; // 192.168.137.200
    localparam [47:0] HOST_MAC = 48'h10_20_30_40_50_60;
    localparam [31:0] HOST_IP  = 32'hC0_A8_89_01; // 192.168.137.1
    localparam [15:0] TRIGGER_PORT = 16'd9997;
    localparam [15:0] IPERF_PORT   = 16'd5001;
    localparam [15:0] LISTEN_PORT  = 16'd5002;
    localparam [13:0] BLAST_PAYLOAD_SIZE = 14'd1472;
    localparam [15:0] EXPECTED_GMII_FRAME_LEN =
        16'd8 + 16'd14 + 16'd20 + 16'd8 + {2'd0, BLAST_PAYLOAD_SIZE} + 16'd4;

    reg [7:0] s_axis_tdata;
    reg       s_axis_tvalid;
    reg       s_axis_tlast;
    reg       s_axis_tsof;
    reg       s_axis_terror;

    wire [7:0]  udp_data;
    wire        udp_valid;
    wire        udp_last;
    wire [31:0] udp_src_ip;
    wire [15:0] udp_src_port;
    wire [15:0] udp_dst_port;
    wire [15:0] udp_length;
    wire [47:0] rx_src_mac;

    net_rx u_net_rx (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tsof   (s_axis_tsof),
        .s_axis_terror (s_axis_terror),
        .arp_data      (),
        .arp_valid     (),
        .arp_last      (),
        .icmp_data     (),
        .icmp_valid    (),
        .icmp_last     (),
        .icmp_src_ip   (),
        .udp_data      (udp_data),
        .udp_valid     (udp_valid),
        .udp_last      (udp_last),
        .udp_src_ip    (udp_src_ip),
        .udp_src_port  (udp_src_port),
        .udp_dst_port  (udp_dst_port),
        .udp_length    (udp_length),
        .rx_src_mac    (rx_src_mac),
        .our_ip        (OUR_IP)
    );

    wire        trig_start;
    wire [47:0] trig_dst_mac;
    wire [31:0] trig_dst_ip;
    wire [15:0] trig_dst_port;
    wire [15:0] trig_src_port;
    wire [23:0] trig_ifg_delay;
    wire [31:0] trig_count;

    reg [47:0] blast_dst_mac;
    reg [31:0] blast_dst_ip;
    reg [15:0] blast_dst_port;
    reg [15:0] blast_src_port;
    reg [31:0] blast_remaining;
    reg [23:0] blast_ifg_delay;

    udp_blast_trigger #(
        .TRIGGER_PORT(TRIGGER_PORT),
        .IGNORE_SRC_PORT(IPERF_PORT),
        .DEFAULT_COUNT(32'd1000000)
    ) u_trigger (
        .clk             (clk),
        .rst_n           (rst_n),
        .udp_rx_data     (udp_data),
        .udp_rx_valid    (udp_valid),
        .udp_rx_last     (udp_last),
        .udp_rx_src_mac  (rx_src_mac),
        .udp_rx_src_ip   (udp_src_ip),
        .udp_rx_src_port (udp_src_port),
        .udp_rx_dst_port (udp_dst_port),
        .busy            (blast_remaining != 32'd0),
        .start           (trig_start),
        .dst_mac         (trig_dst_mac),
        .dst_ip          (trig_dst_ip),
        .dst_port        (trig_dst_port),
        .src_port        (trig_src_port),
        .ifg_delay       (trig_ifg_delay),
        .packet_count    (trig_count)
    );

    wire [7:0] tx_data;
    wire       tx_valid;
    wire       tx_last;
    wire       tx_ready;
    wire       tx_start;
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire       tx_active;

    reg tx_start_d;
    wire tx_start_pulse = tx_start && !tx_start_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blast_dst_mac   <= 48'd0;
            blast_dst_ip    <= 32'd0;
            blast_dst_port  <= 16'd0;
            blast_src_port  <= 16'd0;
            blast_remaining <= 32'd0;
            blast_ifg_delay <= 24'd0;
            tx_start_d      <= 1'b0;
        end else begin
            tx_start_d <= tx_start;
            if (trig_start && blast_remaining == 32'd0) begin
                blast_dst_mac   <= trig_dst_mac;
                blast_dst_ip    <= trig_dst_ip;
                blast_dst_port  <= trig_dst_port;
                blast_src_port  <= trig_src_port;
                blast_ifg_delay <= trig_ifg_delay;
                blast_remaining <= trig_count;
            end else if (tx_start_pulse && blast_remaining != 32'd0) begin
                blast_remaining <= blast_remaining - 32'd1;
            end
        end
    end

    udp_blast u_blast (
        .clk               (clk),
        .rst_n             (rst_n),
        .our_mac           (OUR_MAC),
        .our_ip            (OUR_IP),
        .dst_mac           (blast_dst_mac),
        .dst_ip            (blast_dst_ip),
        .dst_port          (blast_dst_port),
        .src_port          (blast_src_port),
        .payload_size      (BLAST_PAYLOAD_SIZE),
        .enable            (blast_remaining != 32'd0),
        .inter_frame_delay (blast_ifg_delay),
        .pkts_sent         (),
        .pkt_done_pulse    (),
        .tx_data           (tx_data),
        .tx_valid          (tx_valid),
        .tx_last           (tx_last),
        .tx_ready          (tx_ready),
        .tx_start          (tx_start)
    );

    eth_mac_tx u_mac_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (1'b1),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (tx_data),
        .s_axis_tvalid (tx_valid),
        .s_axis_tready (tx_ready),
        .s_axis_tlast  (tx_last),
        .s_axis_tkeep  (1'b1),
        .tx_active     (tx_active),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

    reg gmii_tx_en_d;
    reg [15:0] gmii_byte_cnt;
    reg [15:0] gmii_last_frame_len;
    reg [31:0] gmii_frame_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gmii_tx_en_d       <= 1'b0;
            gmii_byte_cnt      <= 16'd0;
            gmii_last_frame_len <= 16'd0;
            gmii_frame_cnt     <= 32'd0;
        end else begin
            gmii_tx_en_d <= gmii_tx_en;
            if (gmii_tx_en) begin
                gmii_byte_cnt <= gmii_byte_cnt + 16'd1;
            end else if (gmii_tx_en_d) begin
                gmii_last_frame_len <= gmii_byte_cnt;
                gmii_frame_cnt      <= gmii_frame_cnt + 32'd1;
                gmii_byte_cnt       <= 16'd0;
            end
        end
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

    task send_byte;
        input [7:0] b;
        input first;
        input last;
        begin
            @(negedge clk);
            s_axis_tdata  = b;
            s_axis_tvalid = 1'b1;
            s_axis_tsof   = first;
            s_axis_tlast  = last;
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tsof   = 1'b0;
            s_axis_tlast  = 1'b0;
        end
    endtask

    task send_trigger_frame;
        integer i;
        reg [15:0] ip_len;
        reg [15:0] udp_len;
        begin
            ip_len = 16'd37;  // 20 IP + 8 UDP + 9 payload
            udp_len = 16'd17; // 8 UDP + 9 payload

            // Ethernet header
            send_byte(OUR_MAC[47:40], 1'b1, 1'b0);
            send_byte(OUR_MAC[39:32], 1'b0, 1'b0);
            send_byte(OUR_MAC[31:24], 1'b0, 1'b0);
            send_byte(OUR_MAC[23:16], 1'b0, 1'b0);
            send_byte(OUR_MAC[15:8],  1'b0, 1'b0);
            send_byte(OUR_MAC[7:0],   1'b0, 1'b0);
            send_byte(HOST_MAC[47:40], 1'b0, 1'b0);
            send_byte(HOST_MAC[39:32], 1'b0, 1'b0);
            send_byte(HOST_MAC[31:24], 1'b0, 1'b0);
            send_byte(HOST_MAC[23:16], 1'b0, 1'b0);
            send_byte(HOST_MAC[15:8],  1'b0, 1'b0);
            send_byte(HOST_MAC[7:0],   1'b0, 1'b0);
            send_byte(8'h08, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);

            // IPv4 header. Checksum is ignored by net_rx.
            send_byte(8'h45, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(ip_len[15:8], 1'b0, 1'b0);
            send_byte(ip_len[7:0],  1'b0, 1'b0);
            send_byte(8'h12, 1'b0, 1'b0);
            send_byte(8'h34, 1'b0, 1'b0);
            send_byte(8'h40, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h40, 1'b0, 1'b0);
            send_byte(8'h11, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(HOST_IP[31:24], 1'b0, 1'b0);
            send_byte(HOST_IP[23:16], 1'b0, 1'b0);
            send_byte(HOST_IP[15:8],  1'b0, 1'b0);
            send_byte(HOST_IP[7:0],   1'b0, 1'b0);
            send_byte(OUR_IP[31:24], 1'b0, 1'b0);
            send_byte(OUR_IP[23:16], 1'b0, 1'b0);
            send_byte(OUR_IP[15:8],  1'b0, 1'b0);
            send_byte(OUR_IP[7:0],   1'b0, 1'b0);

            // UDP header
            send_byte(8'h9c, 1'b0, 1'b0); // src port 40000
            send_byte(8'h40, 1'b0, 1'b0);
            send_byte(TRIGGER_PORT[15:8], 1'b0, 1'b0);
            send_byte(TRIGGER_PORT[7:0],  1'b0, 1'b0);
            send_byte(udp_len[15:8], 1'b0, 1'b0);
            send_byte(udp_len[7:0],  1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);

            // Trigger payload: ifg=0, count=1000, dst port=5002.
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h00, 1'b0, 1'b0);
            send_byte(8'h03, 1'b0, 1'b0);
            send_byte(8'he8, 1'b0, 1'b0);
            send_byte(LISTEN_PORT[15:8], 1'b0, 1'b0);
            send_byte(LISTEN_PORT[7:0],  1'b0, 1'b0);

            // Ethernet padding, as a real short UDP trigger frame carries.
            for (i = 0; i < 17; i = i + 1)
                send_byte(8'h00, 1'b0, (i == 16));
        end
    endtask

    integer cycle;
    integer tx_seen;

    initial begin
        $dumpfile("tb_udp_blast_path.vcd");
        $dumpvars(0, tb_udp_blast_path);

        s_axis_tdata = 8'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        s_axis_tsof = 1'b0;
        s_axis_terror = 1'b0;

        #50;
        rst_n = 1'b1;
        #30;

        send_trigger_frame;

        tx_seen = 0;
        for (cycle = 0; cycle < 5000; cycle = cycle + 1) begin
            @(posedge clk);
            if (tx_valid)
                tx_seen = 1;
        end

        check("trigger latched dst mac", blast_dst_mac == HOST_MAC);
        check("trigger latched dst ip", blast_dst_ip == HOST_IP);
        check("trigger latched dst port", blast_dst_port == LISTEN_PORT);
        check("trigger latched src port", blast_src_port == TRIGGER_PORT);
        check("trigger parsed count", blast_remaining != 32'd0);
        check("blast emitted bytes", tx_seen);
        check("MAC emitted blast frame", gmii_frame_cnt != 32'd0);
        check("MAC frame includes preamble and FCS", gmii_last_frame_len == EXPECTED_GMII_FRAME_LEN);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
