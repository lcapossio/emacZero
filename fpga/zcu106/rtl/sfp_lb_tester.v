// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// sfp_lb_tester.v - Traffic generator/checker for the ZCU106 SFP loopback
//
// Plays a host on the far end of the link: its own eth_mac_sys (GMII mode, MAC
// 02:00:00:00:00:02, IP 192.168.137.1) sends requests to the emacZero demo
// (zcu106_eth_demo: 02:00:00:00:00:01, 192.168.137.200) and checks each reply:
//
//   ARP request  who-has 192.168.137.200       -> ARP reply
//   ICMP echo    id 0xBEEF, seq n, 18..1472 B  -> echo reply, same payload
//   UDP to 9999  18..1472 B payload            -> echo, ports swapped
//
// Payloads start at 18 bytes, the smallest that needs no Ethernet padding;
// short mode covers the padded sizes below that.
//
// The three kinds rotate, one transaction in flight at a time, with payload
// lengths stepping through their range and a sequence-seeded byte pattern.
// Each reply is checked byte by byte against the expected frame (fields the
// responder may choose, such as IP ID/TTL and the checksums, are not
// compared), plus its length, terror, the IPv4 header checksum and the ICMP
// checksum. No reply within ~1 ms counts as a timeout.
//
// Negative mode (ctrl[2]) adds a fourth kind to the rotation: a frame the
// demo must not answer, cycling through eight variants (based on a 32-byte
// ping unless noted):
//   0 wrong destination MAC (02:00:00:00:00:11)
//   1 wrong destination IP (192.168.137.201)
//   2 ARP request for 192.168.137.201
//   3 UDP to port 9998
//   4 bad IPv4 header checksum
//   5 bad ICMP checksum
//   6 bad FCS (one data bit flipped on GMII after the MAC)
//   7 GMII tx_er in the middle of the frame
// Silence for 200 us counts as ok_neg; a frame in that window counts as
// neg_replies (not bad) and sets neg_fail[variant].
//
// Short mode (ctrl[3]) uses ICMP payloads of 0..17 bytes and UDP payloads of
// 1..18 bytes (all but 18 need Ethernet padding) and checks for replies of
// the request's own length. A 0-byte UDP datagram is not sent: net_rx hands
// datagrams on byte by byte, so an empty one never reaches udp_echo.
//
// ctrl (any clock domain; synchronized here): [0] run  [1] clear counters
//   [2] negative frames  [3] short payloads
// status (clk domain; stop traffic before reading for a coherent view):
//   [31:0]    tx_count     requests sent
//   [63:32]   ok_arp       correct ARP replies
//   [95:64]   ok_icmp      correct ICMP echo replies
//   [127:96]  ok_udp       correct UDP echoes
//   [159:128] bad          wrong replies (see first_* for the first one)
//   [191:160] timeouts     requests with no reply
//   [207:192] max_rtt      longest request-end to reply-end time, cycles
//   [211:208] first_reason 1 byte  2 length  3 terror  4 IP csum
//                          5 ICMP csum  6 timeout  7 unexpected frame
//   [213:212] first_kind   0 ARP  1 ICMP  2 UDP
//   [229:214] first_idx    byte offset of the first mismatch (reason 1)
//   [237:230] first_got    received byte   (reason 1)
//   [245:238] first_exp    expected byte   (reason 1)
//   [261:246] first_seq    sequence number of the first bad transaction
//   [262]     init_done    [263] run (synced)
//   [295:264] ok_neg       negative frames correctly ignored
//   [303:296] neg_fail     negative variants that got a reply
//   [351:304] rx_bytes     bytes in correct replies (Ethernet frame, no FCS)
//   [383:352] neg_replies  replies to negative frames
// Verilog 2001
// =============================================================================

module sfp_lb_tester (
    input  wire         clk,           // 125 MHz
    input  wire         rst_n,
    input  wire [3:0]   ctrl,
    input  wire         link_ok,       // both 1000BASE-X links up

    // GMII to the PCS/PMA (clk domain)
    output wire [7:0]   gmii_txd,
    output wire         gmii_tx_en,
    output wire         gmii_tx_er,
    input  wire [7:0]   gmii_rxd,
    input  wire         gmii_rx_dv,
    input  wire         gmii_rx_er,

    output wire [383:0] status,
    output reg          ok_pulse,      // one cycle per correct reply
    output reg          bad_pulse      // one cycle per bad reply or timeout
);

    localparam [47:0] TM = 48'h02_00_00_00_00_02;   // tester MAC
    localparam [47:0] DM = 48'h02_00_00_00_00_01;   // demo MAC
    localparam [31:0] TI = 32'hC0_A8_89_01;         // 192.168.137.1
    localparam [31:0] DI = 32'hC0_A8_89_C8;         // 192.168.137.200
    localparam [15:0] UDP_PORT  = 16'd9999;
    localparam [15:0] ICMP_ID   = 16'hBEEF;
    localparam [1:0]  K_ARP = 2'd0, K_ICMP = 2'd1, K_UDP = 2'd2, K_NEG = 2'd3;
    localparam [16:0] TIMEOUT = 17'h1FFFF;          // ~1.05 ms
    localparam [16:0] NEG_WIN = 17'd25000;          // 200 us

    // =========================================================================
    // Control synchronizers (static levels, so bitwise synchronizers are fine)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [3:0] ctrl_s0, ctrl_s1;
    always @(posedge clk) begin
        ctrl_s0 <= ctrl;
        ctrl_s1 <= ctrl_s0;
    end
    wire run    = ctrl_s1[0];
    wire clr    = ctrl_s1[1];
    wire neg_en = ctrl_s1[2];
    wire short  = ctrl_s1[3];

    // =========================================================================
    // Tester MAC. After reset one AXI-Lite write sets MAC_LO so the MAC
    // address becomes 02:00:00:00:00:02 (MAC_HI keeps its 0x0200 default).
    // =========================================================================
    reg         aw_valid, w_valid, init_done;
    wire        aw_ready, w_ready, b_valid;

    reg  [7:0]  tx_tdata;
    reg         tx_tvalid, tx_tlast;
    wire        tx_tready;
    wire [7:0]  rx_tdata;
    wire        rx_tvalid, rx_tlast, rx_terror;
    wire [7:0]  mac_txd;
    wire        mac_tx_en, mac_tx_er;

    eth_mac_sys #(
        .PHY_INTERFACE ("GMII"),
        .CLK_FREQ_HZ   (125_000_000)
    ) u_mac (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axi_awaddr   (8'h0C),       // MAC_LO
        .s_axi_awvalid  (aw_valid),
        .s_axi_awready  (aw_ready),
        .s_axi_wdata    (TM[31:0]),
        .s_axi_wstrb    (4'hF),
        .s_axi_wvalid   (w_valid),
        .s_axi_wready   (w_ready),
        .s_axi_bresp    (),
        .s_axi_bvalid   (b_valid),
        .s_axi_bready   (1'b1),
        .s_axi_araddr   (8'd0),
        .s_axi_arvalid  (1'b0),
        .s_axi_arready  (),
        .s_axi_rdata    (),
        .s_axi_rresp    (),
        .s_axi_rvalid   (),
        .s_axi_rready   (1'b1),
        .s_axis_tdata   (tx_tdata),
        .s_axis_tvalid  (tx_tvalid),
        .s_axis_tready  (tx_tready),
        .s_axis_tlast   (tx_tlast),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (rx_tlast),
        .m_axis_terror  (rx_terror),
        .m_axis_tsof    (),
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (1'b0),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        .clk_125        (clk),
        .clk_125_90     (1'b0),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        .phy_gmii_txd    (mac_txd),
        .phy_gmii_tx_en  (mac_tx_en),
        .phy_gmii_tx_er  (mac_tx_er),
        .phy_gmii_txc    (),
        .phy_gmii_rx_clk (clk),
        .phy_gmii_rxd    (gmii_rxd),
        .phy_gmii_rx_dv  (gmii_rx_dv),
        .phy_gmii_rx_er  (gmii_rx_er),
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (),
        .irq            ()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_valid  <= 1'b1;
            w_valid   <= 1'b1;
            init_done <= 1'b0;
        end else begin
            if (aw_valid && aw_ready) aw_valid <= 1'b0;
            if (w_valid && w_ready)   w_valid  <= 1'b0;
            if (b_valid)              init_done <= 1'b1;
        end
    end

    // =========================================================================
    // Helpers
    // =========================================================================
    function [15:0] fold;              // one's-complement fold of a 32-bit sum
        input [31:0] s;
        reg   [31:0] t;
        begin
            t    = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            t    = {16'd0, t[15:0]} + {16'd0, t[31:16]};
            fold = t[15:0];
        end
    endfunction

    function [7:0] pat;                // payload byte i of transaction s
        input [15:0] i;
        input [15:0] s;
        begin
            pat = i[7:0] ^ (s[7:0] + i[15:8]);
        end
    endfunction

    // =========================================================================
    // Transaction state
    // =========================================================================
    localparam [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_SUM = 3'd2,
                     S_SEND = 3'd3, S_WAIT = 3'd4, S_GAP = 3'd5;
    reg  [2:0]  state;
    reg  [1:0]  kind;
    reg  [15:0] seq;
    reg  [15:0] plen;                  // payload length (ICMP data / UDP data)
    reg  [15:0] flen;                  // request frame length
    reg  [15:0] ip_len;
    reg  [15:0] ip_csum, icmp_csum;
    reg  [31:0] sum_acc;
    reg  [15:0] idx;
    reg  [15:0] icmp_step;
    reg  [15:0] udp_step;
    reg  [16:0] timer;
    reg  [15:0] rtt;
    reg  [3:0]  gap_cnt;

    // Frame template and deviations for this transaction (set in S_PREP):
    // the request is built as kind fk, and negative variants change one thing
    reg  [1:0]  fk;
    reg  [47:0] q_dm;
    reg  [31:0] q_di;
    reg  [15:0] q_dport;
    reg         q_bad_ipcs, q_bad_iccs, q_fcs, q_txer;
    reg  [2:0]  neg_var;
    reg  [4:0]  short_step;            // 0..17

    // GMII fault injection after the MAC: at frame byte 42 (GMII byte 50,
    // after preamble and SFD), flip bit 4 (bad FCS) or assert tx_er
    reg  [11:0] gbyte;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  gbyte <= 12'd0;
        else if (!mac_tx_en)         gbyte <= 12'd0;
        else if (gbyte != 12'hFFF)   gbyte <= gbyte + 12'd1;
    end
    wire inject = mac_tx_en && (gbyte == 12'd50) && (kind == K_NEG);
    assign gmii_txd   = mac_txd ^ ((inject && q_fcs) ? 8'h10 : 8'h00);
    assign gmii_tx_en = mac_tx_en;
    assign gmii_tx_er = mac_tx_er | (inject && q_txer);

    wire [15:0] udp_sport = 16'hC000 | {4'd0, seq[11:0]};
    wire [15:0] udp_len_w = ip_len - 16'd20;      // UDP header + data
    wire [7:0]  proto     = (fk == K_UDP) ? 8'h11 : 8'h01;

    // Request byte at idx
    reg  [7:0]  tx_byte;
    always @* begin
        tx_byte = 8'h00;
        if (fk == K_ARP) begin
            case (idx)
                16'd0, 16'd1, 16'd2, 16'd3, 16'd4, 16'd5: tx_byte = 8'hFF;
                16'd6:  tx_byte = TM[47:40];  16'd7:  tx_byte = TM[39:32];
                16'd8:  tx_byte = TM[31:24];  16'd9:  tx_byte = TM[23:16];
                16'd10: tx_byte = TM[15:8];   16'd11: tx_byte = TM[7:0];
                16'd12: tx_byte = 8'h08;      16'd13: tx_byte = 8'h06;
                16'd14: tx_byte = 8'h00;      16'd15: tx_byte = 8'h01;
                16'd16: tx_byte = 8'h08;      16'd17: tx_byte = 8'h00;
                16'd18: tx_byte = 8'h06;      16'd19: tx_byte = 8'h04;
                16'd20: tx_byte = 8'h00;      16'd21: tx_byte = 8'h01;
                16'd22: tx_byte = TM[47:40];  16'd23: tx_byte = TM[39:32];
                16'd24: tx_byte = TM[31:24];  16'd25: tx_byte = TM[23:16];
                16'd26: tx_byte = TM[15:8];   16'd27: tx_byte = TM[7:0];
                16'd28: tx_byte = TI[31:24];  16'd29: tx_byte = TI[23:16];
                16'd30: tx_byte = TI[15:8];   16'd31: tx_byte = TI[7:0];
                16'd38: tx_byte = q_di[31:24];  16'd39: tx_byte = q_di[23:16];
                16'd40: tx_byte = q_di[15:8];   16'd41: tx_byte = q_di[7:0];
                default: tx_byte = 8'h00;     // target MAC (32..37) = 0
            endcase
        end else if (idx >= 16'd42) begin
            tx_byte = pat(idx - 16'd42, seq);
        end else begin
            case (idx)
                16'd0:  tx_byte = q_dm[47:40];  16'd1:  tx_byte = q_dm[39:32];
                16'd2:  tx_byte = q_dm[31:24];  16'd3:  tx_byte = q_dm[23:16];
                16'd4:  tx_byte = q_dm[15:8];   16'd5:  tx_byte = q_dm[7:0];
                16'd6:  tx_byte = TM[47:40];  16'd7:  tx_byte = TM[39:32];
                16'd8:  tx_byte = TM[31:24];  16'd9:  tx_byte = TM[23:16];
                16'd10: tx_byte = TM[15:8];   16'd11: tx_byte = TM[7:0];
                16'd12: tx_byte = 8'h08;      16'd13: tx_byte = 8'h00;
                16'd14: tx_byte = 8'h45;      16'd15: tx_byte = 8'h00;
                16'd16: tx_byte = ip_len[15:8];
                16'd17: tx_byte = ip_len[7:0];
                16'd18: tx_byte = seq[15:8];  16'd19: tx_byte = seq[7:0];
                16'd20: tx_byte = 8'h00;      16'd21: tx_byte = 8'h00;
                16'd22: tx_byte = 8'h40;      16'd23: tx_byte = proto;
                16'd24: tx_byte = ip_csum[15:8];
                16'd25: tx_byte = ip_csum[7:0];
                16'd26: tx_byte = TI[31:24];  16'd27: tx_byte = TI[23:16];
                16'd28: tx_byte = TI[15:8];   16'd29: tx_byte = TI[7:0];
                16'd30: tx_byte = q_di[31:24];  16'd31: tx_byte = q_di[23:16];
                16'd32: tx_byte = q_di[15:8];   16'd33: tx_byte = q_di[7:0];
                default: begin
                    if (fk == K_ICMP) begin
                        case (idx)
                            16'd34: tx_byte = 8'h08;
                            16'd35: tx_byte = 8'h00;
                            16'd36: tx_byte = icmp_csum[15:8];
                            16'd37: tx_byte = icmp_csum[7:0];
                            16'd38: tx_byte = ICMP_ID[15:8];
                            16'd39: tx_byte = ICMP_ID[7:0];
                            16'd40: tx_byte = seq[15:8];
                            default: tx_byte = seq[7:0];     // 41
                        endcase
                    end else begin
                        case (idx)
                            16'd34: tx_byte = udp_sport[15:8];
                            16'd35: tx_byte = udp_sport[7:0];
                            16'd36: tx_byte = q_dport[15:8];
                            16'd37: tx_byte = q_dport[7:0];
                            16'd38: tx_byte = udp_len_w[15:8];
                            16'd39: tx_byte = udp_len_w[7:0];
                            default: tx_byte = 8'h00;        // csum 0
                        endcase
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // RX checker
    // =========================================================================
    reg  [15:0] ridx;
    reg         r_mis;                 // a compared byte differed
    reg  [15:0] r_mis_idx;
    reg  [7:0]  r_mis_got, r_mis_exp;
    reg  [31:0] r_ipsum, r_icsum;
    wire [15:0] exp_len = (flen < 16'd60) ? 16'd60 : flen;

    // Expected reply byte at ridx, and whether it is compared
    reg  [7:0]  exp_byte;
    reg         exp_chk;
    always @* begin
        exp_byte = 8'h00;
        exp_chk  = 1'b1;
        if (ridx >= flen) begin
            exp_chk = 1'b0;                          // padding
        end else if (ridx < 16'd12) begin
            case (ridx)
                16'd0:  exp_byte = TM[47:40];  16'd1:  exp_byte = TM[39:32];
                16'd2:  exp_byte = TM[31:24];  16'd3:  exp_byte = TM[23:16];
                16'd4:  exp_byte = TM[15:8];   16'd5:  exp_byte = TM[7:0];
                16'd6:  exp_byte = DM[47:40];  16'd7:  exp_byte = DM[39:32];
                16'd8:  exp_byte = DM[31:24];  16'd9:  exp_byte = DM[23:16];
                16'd10: exp_byte = DM[15:8];   default: exp_byte = DM[7:0];
            endcase
        end else if (kind == K_ARP) begin
            case (ridx)
                16'd12: exp_byte = 8'h08;      16'd13: exp_byte = 8'h06;
                16'd14: exp_byte = 8'h00;      16'd15: exp_byte = 8'h01;
                16'd16: exp_byte = 8'h08;      16'd17: exp_byte = 8'h00;
                16'd18: exp_byte = 8'h06;      16'd19: exp_byte = 8'h04;
                16'd20: exp_byte = 8'h00;      16'd21: exp_byte = 8'h02;
                16'd22: exp_byte = DM[47:40];  16'd23: exp_byte = DM[39:32];
                16'd24: exp_byte = DM[31:24];  16'd25: exp_byte = DM[23:16];
                16'd26: exp_byte = DM[15:8];   16'd27: exp_byte = DM[7:0];
                16'd28: exp_byte = DI[31:24];  16'd29: exp_byte = DI[23:16];
                16'd30: exp_byte = DI[15:8];   16'd31: exp_byte = DI[7:0];
                16'd32: exp_byte = TM[47:40];  16'd33: exp_byte = TM[39:32];
                16'd34: exp_byte = TM[31:24];  16'd35: exp_byte = TM[23:16];
                16'd36: exp_byte = TM[15:8];   16'd37: exp_byte = TM[7:0];
                16'd38: exp_byte = TI[31:24];  16'd39: exp_byte = TI[23:16];
                16'd40: exp_byte = TI[15:8];   default: exp_byte = TI[7:0];
            endcase
        end else if (ridx >= 16'd42) begin
            exp_byte = pat(ridx - 16'd42, seq);
        end else begin
            case (ridx)
                16'd12: exp_byte = 8'h08;      16'd13: exp_byte = 8'h00;
                16'd14: exp_byte = 8'h45;
                16'd16: exp_byte = ip_len[15:8];
                16'd17: exp_byte = ip_len[7:0];
                16'd23: exp_byte = proto;
                16'd26: exp_byte = DI[31:24];  16'd27: exp_byte = DI[23:16];
                16'd28: exp_byte = DI[15:8];   16'd29: exp_byte = DI[7:0];
                16'd30: exp_byte = TI[31:24];  16'd31: exp_byte = TI[23:16];
                16'd32: exp_byte = TI[15:8];   16'd33: exp_byte = TI[7:0];
                // TOS, ID, flags/fragment, TTL and the IP checksum are the
                // responder's choice; the checksum is verified by summing.
                16'd15, 16'd18, 16'd19, 16'd20, 16'd21, 16'd22,
                16'd24, 16'd25: exp_chk = 1'b0;
                default: begin
                    if (kind == K_ICMP) begin
                        case (ridx)
                            16'd34: exp_byte = 8'h00;        // echo reply
                            16'd35: exp_byte = 8'h00;
                            16'd38: exp_byte = ICMP_ID[15:8];
                            16'd39: exp_byte = ICMP_ID[7:0];
                            16'd40: exp_byte = seq[15:8];
                            16'd41: exp_byte = seq[7:0];
                            default: exp_chk = 1'b0;         // 36, 37 csum
                        endcase
                    end else begin
                        case (ridx)
                            16'd34: exp_byte = UDP_PORT[15:8];
                            16'd35: exp_byte = UDP_PORT[7:0];
                            16'd36: exp_byte = udp_sport[15:8];
                            16'd37: exp_byte = udp_sport[7:0];
                            16'd38: exp_byte = udp_len_w[15:8];
                            16'd39: exp_byte = udp_len_w[7:0];
                            default: exp_chk = 1'b0;         // 40, 41 csum
                        endcase
                    end
                end
            endcase
        end
    end

    // One's-complement running sums over the IPv4 header and the ICMP message
    wire [15:0] rx_word  = ridx[0] ? {8'd0, rx_tdata} : {rx_tdata, 8'd0};
    wire        in_iphdr = (ridx >= 16'd14) && (ridx < 16'd34);
    wire        in_icmp  = (ridx >= 16'd34) && (ridx < flen);

    // =========================================================================
    // Counters and the first failure
    // =========================================================================
    reg [31:0] tx_count, ok_arp, ok_icmp, ok_udp, bad, timeouts;
    reg [31:0] ok_neg, neg_replies;
    reg [7:0]  neg_fail;
    reg [47:0] rx_bytes;
    reg [15:0] max_rtt;
    reg        have_first;
    reg [3:0]  first_reason;
    reg [1:0]  first_kind;
    reg [15:0] first_idx, first_seq;
    reg [7:0]  first_got, first_exp;

    // Evaluate a finished reply (valid on the cycle with rx_tlast)
    wire        last_mis   = exp_chk && (rx_tdata != exp_byte);
    wire        any_mis    = r_mis || last_mis;
    wire [15:0] len_now    = ridx + 16'd1;
    wire [31:0] ipsum_now  = r_ipsum;          // header ends at byte 33
    wire [31:0] icsum_now  = in_icmp ? r_icsum + rx_word : r_icsum;
    reg  [3:0]  reply_reason;
    always @* begin
        if (state != S_WAIT || kind == K_NEG)             reply_reason = 4'd7;
        else if (rx_terror)                               reply_reason = 4'd3;
        else if (any_mis)                                 reply_reason = 4'd1;
        else if (len_now != exp_len)                      reply_reason = 4'd2;
        else if (kind != K_ARP && fold(ipsum_now) != 16'hFFFF)
                                                          reply_reason = 4'd4;
        else if (kind == K_ICMP && fold(icsum_now) != 16'hFFFF)
                                                          reply_reason = 4'd5;
        else                                              reply_reason = 4'd0;
    end

    task note_bad;
        input [3:0] reason;
        begin
            bad       <= bad + 32'd1;
            bad_pulse <= 1'b1;
            if (!have_first) begin
                have_first   <= 1'b1;
                first_reason <= reason;
                first_kind   <= kind;
                first_seq    <= seq;
                first_idx    <= (reason == 4'd1) ? (r_mis ? r_mis_idx : ridx)
                                                 : 16'd0;
                first_got    <= r_mis ? r_mis_got : rx_tdata;
                first_exp    <= r_mis ? r_mis_exp : exp_byte;
            end
        end
    endtask

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            kind       <= K_ARP;
            seq        <= 16'd0;
            plen       <= 16'd0;
            flen       <= 16'd42;
            ip_len     <= 16'd0;
            ip_csum    <= 16'd0;
            icmp_csum  <= 16'd0;
            sum_acc    <= 32'd0;
            idx        <= 16'd0;
            icmp_step  <= 16'd18;
            udp_step   <= 16'd18;
            timer      <= 17'd0;
            rtt        <= 16'd0;
            gap_cnt    <= 4'd0;
            fk         <= K_ARP;
            q_dm       <= DM;
            q_di       <= DI;
            q_dport    <= UDP_PORT;
            q_bad_ipcs <= 1'b0;
            q_bad_iccs <= 1'b0;
            q_fcs      <= 1'b0;
            q_txer     <= 1'b0;
            neg_var    <= 3'd0;
            short_step <= 5'd0;
            tx_tdata   <= 8'd0;
            tx_tvalid  <= 1'b0;
            tx_tlast   <= 1'b0;
            ridx       <= 16'd0;
            r_mis      <= 1'b0;
            r_mis_idx  <= 16'd0;
            r_mis_got  <= 8'd0;
            r_mis_exp  <= 8'd0;
            r_ipsum    <= 32'd0;
            r_icsum    <= 32'd0;
            tx_count   <= 32'd0;
            ok_arp     <= 32'd0;
            ok_icmp    <= 32'd0;
            ok_udp     <= 32'd0;
            bad        <= 32'd0;
            timeouts   <= 32'd0;
            ok_neg     <= 32'd0;
            neg_replies <= 32'd0;
            neg_fail   <= 8'd0;
            rx_bytes   <= 48'd0;
            max_rtt    <= 16'd0;
            have_first <= 1'b0;
            first_reason <= 4'd0;
            first_kind <= 2'd0;
            first_idx  <= 16'd0;
            first_seq  <= 16'd0;
            first_got  <= 8'd0;
            first_exp  <= 8'd0;
            ok_pulse   <= 1'b0;
            bad_pulse  <= 1'b0;
        end else begin
            ok_pulse  <= 1'b0;
            bad_pulse <= 1'b0;

            // ---------------- request side ----------------
            case (state)
            S_IDLE: begin
                if (run && link_ok && init_done)
                    state <= S_PREP;
            end
            S_PREP: begin
                // ICMP and UDP data 18..1472 B (full 1500-byte IP MTU); short mode
                // sweeps ICMP 0..17 B up and UDP 18..1 B down
                fk         <= kind;
                q_dm       <= DM;
                q_di       <= DI;
                q_dport    <= UDP_PORT;
                q_bad_ipcs <= 1'b0;
                q_bad_iccs <= 1'b0;
                q_fcs      <= 1'b0;
                q_txer     <= 1'b0;
                case (kind)
                    K_ARP:  plen <= 16'd0;
                    K_ICMP: plen <= short ? {11'd0, short_step}
                                          : icmp_step;
                    K_UDP:  plen <= short ? {11'd0, 5'd18 - short_step}
                                          : udp_step;
                    default: begin      // K_NEG: variant neg_var
                        fk   <= (neg_var == 3'd2) ? K_ARP :
                                (neg_var == 3'd3) ? K_UDP : K_ICMP;
                        plen <= (neg_var == 3'd2) ? 16'd0 : 16'd32;
                        case (neg_var)
                            3'd0: q_dm       <= DM ^ 48'h10;
                            3'd1: q_di       <= DI ^ 32'h1;
                            3'd2: q_di       <= DI ^ 32'h1;
                            3'd3: q_dport    <= UDP_PORT - 16'd1;
                            3'd4: q_bad_ipcs <= 1'b1;
                            3'd5: q_bad_iccs <= 1'b1;
                            3'd6: q_fcs      <= 1'b1;
                            default: q_txer  <= 1'b1;
                        endcase
                    end
                endcase
                sum_acc <= 32'd0;
                idx     <= 16'd0;
                state   <= S_SUM;
            end
            S_SUM: begin
                // ip_len/flen from plen; ICMP data sum, one byte per cycle
                ip_len <= 16'd28 + plen;
                flen   <= (fk == K_ARP) ? 16'd42 : 16'd42 + plen;
                if (fk == K_ICMP && idx < plen) begin
                    sum_acc <= sum_acc + (idx[0] ? {24'd0, pat(idx, seq)}
                                                 : {16'd0, pat(idx, seq), 8'd0});
                    idx     <= idx + 16'd1;
                end else begin
                    ip_csum   <= ~fold(32'h4500 + {16'd0, 16'd28 + plen}
                                       + {16'd0, seq} + 32'h0000
                                       + {16'd0, 8'h40, proto}
                                       + TI[31:16] + TI[15:0]
                                       + q_di[31:16] + q_di[15:0])
                                 ^ {15'd0, q_bad_ipcs};
                    icmp_csum <= ~fold(sum_acc + 32'h0800 + ICMP_ID + seq)
                                 ^ {15'd0, q_bad_iccs};
                    idx       <= 16'd0;
                    state     <= S_SEND;
                end
            end
            S_SEND: begin
                if (!tx_tvalid || tx_tready) begin
                    if (tx_tvalid && tx_tlast) begin
                        tx_tvalid <= 1'b0;
                        tx_tlast  <= 1'b0;
                        tx_count  <= tx_count + 32'd1;
                        timer     <= 17'd0;
                        rtt       <= 16'd0;
                        ridx      <= 16'd0;
                        r_mis     <= 1'b0;
                        r_ipsum   <= 32'd0;
                        r_icsum   <= 32'd0;
                        state     <= S_WAIT;
                    end else begin
                        tx_tdata  <= tx_byte;
                        tx_tvalid <= 1'b1;
                        tx_tlast  <= (idx == flen - 16'd1);
                        idx       <= idx + 16'd1;
                    end
                end
            end
            S_WAIT: begin
                timer <= timer + 17'd1;
                if (rtt != 16'hFFFF) rtt <= rtt + 16'd1;
                if (kind == K_NEG) begin
                    if (timer == NEG_WIN) begin     // silence: correct
                        ok_neg   <= ok_neg + 32'd1;
                        ok_pulse <= 1'b1;
                        gap_cnt  <= 4'd0;
                        state    <= S_GAP;
                    end
                end else if (timer == TIMEOUT) begin
                    timeouts  <= timeouts + 32'd1;
                    bad_pulse <= 1'b1;
                    if (!have_first) begin
                        have_first   <= 1'b1;
                        first_reason <= 4'd6;
                        first_kind   <= kind;
                        first_seq    <= seq;
                        first_idx    <= 16'd0;
                        first_got    <= 8'd0;
                        first_exp    <= 8'd0;
                    end
                    gap_cnt <= 4'd0;
                    state   <= S_GAP;
                end
            end
            S_GAP: begin
                gap_cnt <= gap_cnt + 4'd1;
                if (gap_cnt == 4'd15) begin
                    seq  <= seq + 16'd1;
                    kind <= (kind == K_UDP) ? (neg_en ? K_NEG : K_ARP) :
                            (kind == K_NEG) ? K_ARP : kind + 2'd1;
                    if (kind == K_NEG)
                        neg_var <= neg_var + 3'd1;
                    if (kind == K_UDP)
                        short_step <= (short_step == 5'd17) ? 5'd0
                                                            : short_step + 5'd1;
                    // +37 in a cycle of 1455 (18..1472): coprime, so in
                    // time every payload length is sent, crossing the
                    // icmp_echo boundaries that once failed (249, 504 B)
                    if (kind == K_ICMP)
                        icmp_step <= (icmp_step >= 16'd1436) ? icmp_step - 16'd1418
                                                             : icmp_step + 16'd37;
                    if (kind == K_UDP)
                        udp_step  <= (udp_step > 16'd1375) ? udp_step - 16'd1358
                                                           : udp_step + 16'd97;
                    state <= S_IDLE;
                end
            end
            default: state <= S_IDLE;
            endcase

            // ---------------- reply side ----------------
            if (rx_tvalid) begin
                if (!rx_tlast) begin
                    ridx <= ridx + 16'd1;
                    if (last_mis && !r_mis) begin
                        r_mis     <= 1'b1;
                        r_mis_idx <= ridx;
                        r_mis_got <= rx_tdata;
                        r_mis_exp <= exp_byte;
                    end
                    if (in_iphdr) r_ipsum <= r_ipsum + rx_word;
                    if (in_icmp)  r_icsum <= r_icsum + rx_word;
                end else begin
                    ridx    <= 16'd0;
                    r_mis   <= 1'b0;
                    r_ipsum <= 32'd0;
                    r_icsum <= 32'd0;
                    if (reply_reason == 4'd0) begin
                        ok_pulse <= 1'b1;
                        case (kind)
                            K_ARP:   ok_arp  <= ok_arp  + 32'd1;
                            K_ICMP:  ok_icmp <= ok_icmp + 32'd1;
                            default: ok_udp  <= ok_udp  + 32'd1;
                        endcase
                        if (rtt > max_rtt) max_rtt <= rtt;
                        rx_bytes <= rx_bytes + {32'd0, len_now};
                    end else if (state == S_WAIT && kind == K_NEG) begin
                        neg_replies       <= neg_replies + 32'd1;
                        neg_fail[neg_var] <= 1'b1;
                        bad_pulse         <= 1'b1;
                    end else begin
                        note_bad(reply_reason);
                    end
                    if (state == S_WAIT) begin
                        gap_cnt <= 4'd0;
                        state   <= S_GAP;
                    end
                end
            end

            if (clr) begin
                tx_count   <= 32'd0;
                ok_arp     <= 32'd0;
                ok_icmp    <= 32'd0;
                ok_udp     <= 32'd0;
                bad        <= 32'd0;
                timeouts   <= 32'd0;
                ok_neg     <= 32'd0;
                neg_replies <= 32'd0;
                neg_fail   <= 8'd0;
                rx_bytes   <= 48'd0;
                max_rtt    <= 16'd0;
                have_first <= 1'b0;
            end
        end
    end

    assign status = {neg_replies, rx_bytes, neg_fail, ok_neg, run, init_done,
                     first_seq, first_exp, first_got, first_idx, first_kind,
                     first_reason, max_rtt,
                     timeouts, bad, ok_udp, ok_icmp, ok_arp, tx_count};

endmodule
