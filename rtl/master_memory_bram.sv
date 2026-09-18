`timescale 1ns/1ps

// same BRAM, just for the bridge master's local buffer
module master_memory_bram #(
    parameter ADDR_WIDTH = 11,
    parameter DATA_WIDTH = 8,
    parameter MEM_SIZE   = 2048
)(
    input  logic                  clk,
    input  logic                  rstn,
    input  logic                  wen,
    input  logic                  ren,
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [DATA_WIDTH-1:0] wdata,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic                  rvalid
);

    slave_memory_bram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .MEM_SIZE  (MEM_SIZE)
    ) mem (
        .clk(clk), .rstn(rstn), .wen(wen), .ren(ren),
        .addr(addr), .wdata(wdata), .rdata(rdata), .rvalid(rvalid)
    );

endmodule
