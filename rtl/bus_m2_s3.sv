`timescale 1ns/1ps

// interconnect: arbiter + decoder + muxes, 2 masters 3 slaves
module bus_m2_s3 #(
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

    output logic split_grant
);

    logic       msel;
    logic [1:0] ssel;
    logic       m_wdata, m_mode, m_mvalid;
    logic       s_rdata, s_svalid;
    logic       ack;

    // pick active master
    mux2 #(1) wdata_mux (.in0(m1_wdata), .in1(m2_wdata), .sel(msel), .out(m_wdata));
    mux2 #(2) mctrl_mux (
        .in0({m1_mode, m1_mvalid}),
        .in1({m2_mode, m2_mvalid}),
        .sel(msel),
        .out({m_mode, m_mvalid})
    );

    arbiter bus_arbiter (
        .clk        (clk),
        .rstn       (rstn),
        .breq1      (m1_breq),
        .breq2      (m2_breq),
        .sready1    (s1_ready),
        .sready2    (s2_ready),
        .sreadysp   (s3_ready),
        .ssplit     (s3_split),
        .bgrant1    (m1_bgrant),
        .bgrant2    (m2_bgrant),
        .msel       (msel),
        .msplit1    (m1_split),
        .msplit2    (m2_split),
        .split_grant(split_grant)
    );

    addr_decoder #(
        .ADDR_WIDTH       (ADDR_WIDTH),
        .DEVICE_ADDR_WIDTH(ADDR_WIDTH - SLAVE3_MEM_ADDR_WIDTH)
    ) decoder (
        .clk        (clk),
        .rstn       (rstn),
        .mwdata     (m_wdata),
        .mvalid     (m_mvalid),
        .ssplit     (s3_split),
        .split_grant(split_grant),
        .sready1    (s1_ready),
        .sready2    (s2_ready),
        .sready3    (s3_ready),
        .mvalid1    (s1_mvalid),
        .mvalid2    (s2_mvalid),
        .mvalid3    (s3_mvalid),
        .ssel       (ssel),
        .ack        (ack)
    );

    // broadcast data/mode, mvalid already gated per slave
    assign s1_wdata = m_wdata;
    assign s2_wdata = m_wdata;
    assign s3_wdata = m_wdata;
    assign s1_mode  = m_mode;
    assign s2_mode  = m_mode;
    assign s3_mode  = m_mode;

    // read path back to masters
    mux3 #(1) rdata_mux (.in0(s1_rdata),  .in1(s2_rdata),  .in2(s3_rdata),  .sel(ssel), .out(s_rdata));
    mux3 #(1) rctrl_mux (.in0(s1_svalid), .in1(s2_svalid), .in2(s3_svalid), .sel(ssel), .out(s_svalid));

    assign m1_rdata  = s_rdata;
    assign m2_rdata  = s_rdata;
    assign m1_svalid = s_svalid & ~msel;
    assign m2_svalid = s_svalid &  msel;

    // ack only to whoever holds the bus
    assign m1_ack = ack & m1_bgrant;
    assign m2_ack = ack & m2_bgrant;

endmodule
