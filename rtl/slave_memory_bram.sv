`timescale 1ns/1ps

// simple BRAM with 2 cycle read latency + rvalid pulse
module slave_memory_bram #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 8,
    parameter MEM_SIZE   = 4096
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

    logic [DATA_WIDTH-1:0] memory [0:MEM_SIZE-1];

    logic ren_d;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rdata  <= '0;
            rvalid <= 1'b0;
            ren_d  <= 1'b0;
        end else begin
            ren_d <= ren;
            if (wen) memory[addr] <= wdata;
            if (ren) rdata <= memory[addr];
            rvalid <= ren_d;   // data good one cycle after read
        end
    end

endmodule
