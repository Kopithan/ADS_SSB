`timescale 1ns/1ps

// interconnect: arbiter + decoder + muxes, 3 masters 4 targets.
// m1, m2 are the local masters, m3 is the bridge node's master face.
// s1, s2, s3 are the local slaves, sb is the bridge node's slave face.
module bus_m3_s4 #(
    parameter ADDR_WIDTH            = 16,
    parameter DATA_WIDTH            = 8,
    parameter SLAVE1_MEM_ADDR_WIDTH = 11,
    parameter SLAVE2_MEM_ADDR_WIDTH = 12,
    parameter SLAVE3_MEM_ADDR_WIDTH = 12
)(
    input  logic clk,
    input  logic rstn,

    // master 1
    output logic m1_rdata,
    input  logic m1_wdata,
    input  logic m1_mode,
    input  logic m1_mvalid,
    output logic m1_svalid,
    input  logic m1_breq,
    output logic m1_bgrant,
    output logic m1_ack,
    output logic m1_split,

    // master 2
    output logic m2_rdata,
    input  logic m2_wdata,
    input  logic m2_mode,
    input  logic m2_mvalid,
    output logic m2_svalid,
    input  logic m2_breq,
    output logic m2_bgrant,
    output logic m2_ack,
    output logic m2_split,

    // master 3 = bridge master face
    output logic m3_rdata,
    input  logic m3_wdata,
    input  logic m3_mode,
    input  logic m3_mvalid,
    output logic m3_svalid,
    input  logic m3_breq,
    output logic m3_bgrant,
    output logic m3_ack,
    output logic m3_split,

    // slave 1
    input  logic s1_rdata,
    output logic s1_wdata,
    output logic s1_mode,
    output logic s1_mvalid,
    input  logic s1_svalid,
    input  logic s1_ready,

    // slave 2
    input  logic s2_rdata,
    output logic s2_wdata,
    output logic s2_mode,
    output logic s2_mvalid,
    input  logic s2_svalid,
    input  logic s2_ready,

    // slave 3 (split capable)
    input  logic s3_rdata,
    output logic s3_wdata,
    output logic s3_mode,
    output logic s3_mvalid,
    input  logic s3_svalid,
    input  logic s3_ready,
    input  logic s3_split,

    // bridge slave face (split capable)
    input  logic sb_rdata,
    output logic sb_wdata,
    output logic sb_mode,
    output logic sb_mvalid,
    input  logic sb_svalid,
    input  logic sb_ready,
    input  logic sb_split,
    output logic [1:0] sb_dev,

    output logic split_grant,

    // static snapshot for the JTAG diag word (bit 7 is filled in by Sytembus)
    //  [0] ssplit_any  [1] sb_split  [2] split_busy  [4:3] split owner
    //  [5] s3_ready    [6] sb_ready  [7] -           [10:8] arbiter state
    //  [12:11] decoder state
    output logic [12:0] dbg
);

    logic [1:0] msel;
    logic [1:0] ssel;
    logic       m_wdata, m_mode, m_mvalid;
    logic       s_rdata, s_svalid;
    logic       ack;
    logic       ssplit_any, split_busy;
    logic [1:0] arb_owner, dec_state;
    logic [2:0] arb_state;

    // either split capable target can be the one that split
    assign ssplit_any = s3_split | sb_split;

    // pick active master
    mux3 #(1) wdata_mux (.in0(m1_wdata), .in1(m2_wdata), .in2(m3_wdata),
                         .sel(msel), .out(m_wdata));
    mux3 #(2) mctrl_mux (
        .in0({m1_mode, m1_mvalid}),
        .in1({m2_mode, m2_mvalid}),
        .in2({m3_mode, m3_mvalid}),
        .sel(msel),
        .out({m_mode, m_mvalid})
    );

    arbiter3 bus_arbiter (
        .clk        (clk),
        .rstn       (rstn),
        .breq1      (m1_breq),
        .breq2      (m2_breq),
        .breq3      (m3_breq),
        .sready1    (s1_ready),
        .sready2    (s2_ready),
        .sreadysp   (s3_ready & sb_ready),
        .ssplit     (ssplit_any),
        .bgrant1    (m1_bgrant),
        .bgrant2    (m2_bgrant),
        .bgrant3    (m3_bgrant),
        .msel       (msel),
        .msplit1    (m1_split),
        .msplit2    (m2_split),
        .msplit3    (m3_split),
        .split_grant(split_grant),
        .split_busy (split_busy),
        .dbg_owner  (arb_owner),
        .dbg_state  (arb_state)
    );

    // the arbiter can only book-keep ONE split at a time, so while a split is
    // outstanding neither split capable target may be addressed again. the one
    // that split already reports not ready; this covers the other one. a master
    // that tries anyway gets no ack and times out, same as any bad address.
    logic dec_s3_ready, dec_sb_ready;
    assign dec_s3_ready = s3_ready & ~split_busy;
    assign dec_sb_ready = sb_ready & ~split_busy;

    addr_decoder4 #(
        .ADDR_WIDTH       (ADDR_WIDTH),
        .DEVICE_ADDR_WIDTH(ADDR_WIDTH - SLAVE3_MEM_ADDR_WIDTH)
    ) decoder (
        .clk        (clk),
        .rstn       (rstn),
        .mwdata     (m_wdata),
        .mvalid     (m_mvalid),
        .ssplit3    (s3_split),
        .ssplitb    (sb_split),
        .split_grant(split_grant),
        .sready1    (s1_ready),
        .sready2    (s2_ready),
        .sready3    (dec_s3_ready),
        .sreadyb    (dec_sb_ready),
        .mvalid1    (s1_mvalid),
        .mvalid2    (s2_mvalid),
        .mvalid3    (s3_mvalid),
        .mvalidb    (sb_mvalid),
        .ssel       (ssel),
        .bdev       (sb_dev),
        .ack        (ack),
        .dbg_state  (dec_state)
    );

    assign dbg = {dec_state, arb_state, 1'b0, sb_ready, s3_ready,
                  arb_owner, split_busy, sb_split, ssplit_any};

    // broadcast data/mode, mvalid already gated per target
    assign s1_wdata = m_wdata;
    assign s2_wdata = m_wdata;
    assign s3_wdata = m_wdata;
    assign sb_wdata = m_wdata;
    assign s1_mode  = m_mode;
    assign s2_mode  = m_mode;
    assign s3_mode  = m_mode;
    assign sb_mode  = m_mode;

    // read path back to masters
    mux4 #(1) rdata_mux (.in0(s1_rdata),  .in1(s2_rdata),  .in2(s3_rdata),  .in3(sb_rdata),
                         .sel(ssel), .out(s_rdata));
    mux4 #(1) rctrl_mux (.in0(s1_svalid), .in1(s2_svalid), .in2(s3_svalid), .in3(sb_svalid),
                         .sel(ssel), .out(s_svalid));

    assign m1_rdata  = s_rdata;
    assign m2_rdata  = s_rdata;
    assign m3_rdata  = s_rdata;
    assign m1_svalid = s_svalid & (msel == 2'b00);
    assign m2_svalid = s_svalid & (msel == 2'b01);
    assign m3_svalid = s_svalid & (msel == 2'b10);

    // ack only to whoever holds the bus
    assign m1_ack = ack & m1_bgrant;
    assign m2_ack = ack & m2_bgrant;
    assign m3_ack = ack & m3_bgrant;

endmodule
