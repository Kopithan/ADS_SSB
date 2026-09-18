`timescale 1ns/1ps

// small sync fifo
module fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 8
)(
    input  logic                  clk,
    input  logic                  rstn,
    input  logic                  enq,
    input  logic                  deq,
    input  logic [DATA_WIDTH-1:0] data_in,
    output logic [DATA_WIDTH-1:0] data_out,
    output logic                  empty,
    output logic                  full
);

    localparam PTR_W = $clog2(DEPTH);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W-1:0] wptr, rptr;
    logic [PTR_W:0]   count;

    assign empty    = (count == 0);
    assign full     = (count == DEPTH);
    assign data_out = mem[rptr];  // show head, deq pops it

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wptr  <= '0;
            rptr  <= '0;
            count <= '0;
        end else begin
            if (enq && !full) begin
                mem[wptr] <= data_in;
                wptr <= wptr + 1;
            end
            if (deq && !empty)
                rptr <= rptr + 1;

            case ({enq && !full, deq && !empty})
                2'b10: count <= count + 1;
                2'b01: count <= count - 1;
                default: ;
            endcase
        end
    end

endmodule
