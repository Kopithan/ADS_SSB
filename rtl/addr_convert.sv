`timescale 1ns/1ps

// bridge address -> full bus address
// top 2 bits of bb_addr pick the slave, rest is the offset
module addr_convert #(
    parameter BB_ADDR_WIDTH      = 12,
    parameter BUS_ADDR_WIDTH     = 16,
    parameter BUS_MEM_ADDR_WIDTH = 12
)(
    input  logic [BB_ADDR_WIDTH-1:0]  bb_addr,
    output logic [BUS_ADDR_WIDTH-1:0] bus_addr
);

    localparam DEV_W = BUS_ADDR_WIDTH - BUS_MEM_ADDR_WIDTH;

    assign bus_addr = {{(DEV_W-2){1'b0}}, bb_addr[BB_ADDR_WIDTH-1 -: 2],
                       {(BUS_MEM_ADDR_WIDTH-BB_ADDR_WIDTH+2){1'b0}},
                       bb_addr[BB_ADDR_WIDTH-3:0]};

endmodule
