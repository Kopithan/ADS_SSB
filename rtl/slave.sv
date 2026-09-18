`timescale 1ns/1ps

// slave_port + its BRAM in one box
module slave #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 8,
    parameter SPLIT_EN   = 0,
    parameter MEM_SIZE   = 4096
)(
    input  logic clk,
    input  logic rstn,

    input  logic swdata,
    output logic srdata,
    input  logic smode,
    input  logic mvalid,
    input  logic split_grant,
    output logic svalid,
    output logic sready,
    output logic ssplit
);

    logic [DATA_WIDTH-1:0] memrdata, memwdata;
    logic [ADDR_WIDTH-1:0] memaddr;
    logic                  memwen, memren, memrvalid;

    slave_port #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN  (SPLIT_EN)
    ) sp (
        .clk        (clk),
        .rstn       (rstn),
        .smemrdata  (memrdata),
        .rvalid     (memrvalid),
        .smemwen    (memwen),
        .smemren    (memren),
        .smemaddr   (memaddr),
        .smemwdata  (memwdata),
        .swdata     (swdata),
        .srdata     (srdata),
        .smode      (smode),
        .mvalid     (mvalid),
        .split_grant(split_grant),
        .svalid     (svalid),
        .sready     (sready),
        .ssplit     (ssplit)
    );

    slave_memory_bram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .MEM_SIZE  (MEM_SIZE)
    ) sm (
        .clk   (clk),
        .rstn  (rstn),
        .wen   (memwen),
        .ren   (memren),
        .addr  (memaddr),
        .wdata (memwdata),
        .rdata (memrdata),
        .rvalid(memrvalid)
    );

endmodule
