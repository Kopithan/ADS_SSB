`timescale 1ns/1ps

// 2:1 mux, width parameterized
module mux2 #(parameter WIDTH = 1)(
    input  logic [WIDTH-1:0] in0,
    input  logic [WIDTH-1:0] in1,
    input  logic             sel,
    output logic [WIDTH-1:0] out
);
    assign out = sel ? in1 : in0;
endmodule

// 3:1 mux
module mux3 #(parameter WIDTH = 1)(
    input  logic [WIDTH-1:0] in0,
    input  logic [WIDTH-1:0] in1,
    input  logic [WIDTH-1:0] in2,
    input  logic [1:0]       sel,
    output logic [WIDTH-1:0] out
);
    always_comb begin
        unique case (sel)
            2'b00 : out = in0;
            2'b01 : out = in1;
            2'b10 : out = in2;
            default: out = '0;
        endcase
    end
endmodule

// 4:1 mux
module mux4 #(parameter WIDTH = 1)(
    input  logic [WIDTH-1:0] in0,
    input  logic [WIDTH-1:0] in1,
    input  logic [WIDTH-1:0] in2,
    input  logic [WIDTH-1:0] in3,
    input  logic [1:0]       sel,
    output logic [WIDTH-1:0] out
);
    always_comb begin
        unique case (sel)
            2'b00 : out = in0;
            2'b01 : out = in1;
            2'b10 : out = in2;
            2'b11 : out = in3;
            default: out = '0;
        endcase
    end
endmodule
