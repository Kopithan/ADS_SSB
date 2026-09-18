`timescale 1ns/1ps

// hardware top:
// M1, M2 = external device ports (both driven from JTAG), identical.
// S1 = 2K bram, S2 = 4K bram, S3 = 4K bram with SPLIT support,
// BRIDGE = bus_bridge_node, the only uart on the design, the link to the
// far board. Same slave set the unit benches use, so the figures match.
//
// The far board runs this exact same design, so the two address maps are
// identical and neither side needs a translation table. A local master reaches
// the far system by addressing the bridge, and the far system reaches every
// local slave through the bridge's master face:
//
//   0x0000-0x07FF  S1 2K     0x8000-0x87FF  far S1
//   0x1000-0x1FFF  S2 4K     0x9000-0x9FFF  far S2
//   0x2000-0x2FFF  S3 4K     0xA000-0xAFFF  far S3   (split on read)
//
// Both masters are plain master_ports again. Nothing on a master knows the
// link exists, which is what lets EITHER of them talk to the far board.
module Sytembus #(
    parameter ADDR_WIDTH            = 16,
    parameter DATA_WIDTH            = 8,
    parameter SLAVE1_MEM_ADDR_WIDTH = 11,
    parameter SLAVE2_MEM_ADDR_WIDTH = 12,
    parameter SLAVE3_MEM_ADDR_WIDTH = 12,
    parameter CLKS_PER_BIT          = 434,    // 50MHz / 115200, board to board link
    parameter RESP_TIMEOUT          = 500000  // 10ms @ 50MHz
)(
    input  logic clk,
    input  logic rstn,

    // master 1 device interface
    input  logic [ADDR_WIDTH-1:0] d1_addr,
    input  logic [DATA_WIDTH-1:0] d1_wdata,
    output logic [DATA_WIDTH-1:0] d1_rdata,
    input  logic                  d1_valid,
    output logic                  d1_ready,
    input  logic                  d1_mode,

    // master 2 device interface
    input  logic [ADDR_WIDTH-1:0] d2_addr,
    input  logic [DATA_WIDTH-1:0] d2_wdata,
    output logic [DATA_WIDTH-1:0] d2_rdata,
    input  logic                  d2_valid,
    output logic                  d2_ready,
    input  logic                  d2_mode,

    // board to board link, owned by the bridge node
    input  logic rm_rx,
    output logic rm_tx,

    // sticky: far board did not answer a read in time
    output logic br_error,

    // static snapshot of the bus control state, readable over JTAG when the
    // console's diag switch is on. a wedge is a static condition, so one
    // read of this word says exactly which machine is stuck where.
    //  [0] ssplit_any  [1] sb_split  [2] split_busy  [4:3] split owner
    //  [5] s3_ready    [6] sb_ready  [7] LIVE rm_rx pin level
    //  [10:8] arbiter state
    //  link evidence, all since our last far request:
    //  [11] a 0x5A response arrived   [12] any complete byte arrived
    //  [13] our request frame finished transmitting
    //  [14] the uart transmitter ran  [15] rm_rx was seen LOW
    output logic [15:0] dbg
);

    // bus wires
    logic m1_rdata, m1_wdata, m1_mode, m1_mvalid, m1_svalid;
    logic m1_breq, m1_bgrant, m1_ack, m1_split;
    logic m2_rdata, m2_wdata, m2_mode, m2_mvalid, m2_svalid;
    logic m2_breq, m2_bgrant, m2_ack, m2_split;
    logic m3_rdata, m3_wdata, m3_mode, m3_mvalid, m3_svalid;
    logic m3_breq, m3_bgrant, m3_ack, m3_split;
    logic s1_rdata, s1_wdata, s1_mode, s1_mvalid, s1_svalid, s1_ready;
    logic s2_rdata, s2_wdata, s2_mode, s2_mvalid, s2_svalid, s2_ready;
    logic s3_rdata, s3_wdata, s3_mode, s3_mvalid, s3_svalid, s3_ready, s3_split;
    logic sb_rdata, sb_wdata, sb_mode, sb_mvalid, sb_svalid, sb_ready, sb_split;
    logic [1:0] sb_dev;
    logic split_grant;
    logic [12:0] bus_dbg;
    logic        br_rx_any, br_resp_seen, br_rx_level;
    logic        br_req_sent, br_tx_ran, br_rx_low;

    // The top five bits carry LINK evidence rather than bus state. Once the
    // bus itself is known good - every fsm idle, every ready high - the only
    // useful thing left to see is what happened on the wire, and d1_ready on
    // the probe already says whether master 1 is wedged.
    assign dbg = {br_rx_low, br_tx_ran, br_req_sent, br_rx_any, br_resp_seen,
                  bus_dbg[10:8], br_rx_level, bus_dbg[6:0]};

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH)
    ) master1_port (
        .clk(clk), .rstn(rstn),
        .dwdata(d1_wdata), .drdata(d1_rdata), .daddr(d1_addr),
        .dvalid(d1_valid), .dready(d1_ready), .dmode(d1_mode),
        .mrdata(m1_rdata), .mwdata(m1_wdata), .mmode(m1_mode),
        .mvalid(m1_mvalid), .svalid(m1_svalid),
        .mbreq(m1_breq), .mbgrant(m1_bgrant), .ack(m1_ack), .msplit(m1_split),
        .dbg_state()
    );

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH)
    ) master2_port (
        .clk(clk), .rstn(rstn),
        .dwdata(d2_wdata), .drdata(d2_rdata), .daddr(d2_addr),
        .dvalid(d2_valid), .dready(d2_ready), .dmode(d2_mode),
        .mrdata(m2_rdata), .mwdata(m2_wdata), .mmode(m2_mode),
        .mvalid(m2_mvalid), .svalid(m2_svalid),
        .mbreq(m2_breq), .mbgrant(m2_bgrant), .ack(m2_ack), .msplit(m2_split),
        .dbg_state()
    );

    slave #(
        .ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN(0), .MEM_SIZE(2048)
    ) slave1 (
        .clk(clk), .rstn(rstn),
        .srdata(s1_rdata), .swdata(s1_wdata), .smode(s1_mode),
        .svalid(s1_svalid), .mvalid(s1_mvalid), .sready(s1_ready),
        .ssplit(), .split_grant(1'b0)
    );

    slave #(
        .ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN(0), .MEM_SIZE(4096)
    ) slave2 (
        .clk(clk), .rstn(rstn),
        .srdata(s2_rdata), .swdata(s2_wdata), .smode(s2_mode),
        .svalid(s2_svalid), .mvalid(s2_mvalid), .sready(s2_ready),
        .ssplit(), .split_grant(1'b0)
    );

    // the split capable slave. no uart of its own any more: the only link on
    // the design is the bridge node below.
    slave #(
        .ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN(1), .MEM_SIZE(4096)
    ) slave3 (
        .clk(clk), .rstn(rstn),
        .srdata(s3_rdata), .swdata(s3_wdata), .smode(s3_mode),
        .svalid(s3_svalid), .mvalid(s3_mvalid), .sready(s3_ready),
        .ssplit(s3_split), .split_grant(split_grant)
    );

    // the link. slave face at device ids 8/9/10, master face is bus master 3.
    bus_bridge_node #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH),
        .CLKS_PER_BIT(CLKS_PER_BIT), .RESP_TIMEOUT(RESP_TIMEOUT)
    ) bridge (
        .clk(clk), .rstn(rstn),
        .swdata(sb_wdata), .smode(sb_mode), .mvalid(sb_mvalid),
        .split_grant(split_grant), .bdev(sb_dev),
        .srdata(sb_rdata), .svalid(sb_svalid), .sready(sb_ready), .ssplit(sb_split),
        .mrdata(m3_rdata), .mwdata(m3_wdata), .mmode(m3_mode),
        .mmvalid(m3_mvalid), .msvalid(m3_svalid),
        .mbreq(m3_breq), .mbgrant(m3_bgrant), .msplit(m3_split), .ack(m3_ack),
        .u_tx(rm_tx), .u_rx(rm_rx),
        .derror(br_error),
        .dbg_busy(),
        .dbg_rx_level(br_rx_level),
        .dbg_rx_any(br_rx_any),
        .dbg_resp_seen(br_resp_seen),
        .dbg_req_sent(br_req_sent),
        .dbg_tx_ran(br_tx_ran),
        .dbg_rx_low(br_rx_low)
    );

    bus_m3_s4 #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE1_MEM_ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH),
        .SLAVE2_MEM_ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH),
        .SLAVE3_MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH)
    ) bus_inst (
        .clk(clk), .rstn(rstn),
        .m1_rdata(m1_rdata), .m1_wdata(m1_wdata), .m1_mode(m1_mode),
        .m1_mvalid(m1_mvalid), .m1_svalid(m1_svalid),
        .m1_breq(m1_breq), .m1_bgrant(m1_bgrant), .m1_ack(m1_ack), .m1_split(m1_split),
        .m2_rdata(m2_rdata), .m2_wdata(m2_wdata), .m2_mode(m2_mode),
        .m2_mvalid(m2_mvalid), .m2_svalid(m2_svalid),
        .m2_breq(m2_breq), .m2_bgrant(m2_bgrant), .m2_ack(m2_ack), .m2_split(m2_split),
        .m3_rdata(m3_rdata), .m3_wdata(m3_wdata), .m3_mode(m3_mode),
        .m3_mvalid(m3_mvalid), .m3_svalid(m3_svalid),
        .m3_breq(m3_breq), .m3_bgrant(m3_bgrant), .m3_ack(m3_ack), .m3_split(m3_split),
        .s1_rdata(s1_rdata), .s1_wdata(s1_wdata), .s1_mode(s1_mode),
        .s1_mvalid(s1_mvalid), .s1_svalid(s1_svalid), .s1_ready(s1_ready),
        .s2_rdata(s2_rdata), .s2_wdata(s2_wdata), .s2_mode(s2_mode),
        .s2_mvalid(s2_mvalid), .s2_svalid(s2_svalid), .s2_ready(s2_ready),
        .s3_rdata(s3_rdata), .s3_wdata(s3_wdata), .s3_mode(s3_mode),
        .s3_mvalid(s3_mvalid), .s3_svalid(s3_svalid), .s3_ready(s3_ready),
        .s3_split(s3_split),
        .sb_rdata(sb_rdata), .sb_wdata(sb_wdata), .sb_mode(sb_mode),
        .sb_mvalid(sb_mvalid), .sb_svalid(sb_svalid), .sb_ready(sb_ready),
        .sb_split(sb_split), .sb_dev(sb_dev),
        .split_grant(split_grant),
        .dbg(bus_dbg)
    );

endmodule
