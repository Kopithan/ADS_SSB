`timescale 1ns/1ps
//=============================================================================
// liveread_tb
//
// One board with rm_tx looped back to rm_rx, so far accesses are actually
// answered. Counts how many REQUEST frames ONE console far read puts on the
// wire when the far side replies quickly, which is the case a dead-link
// bench cannot show.
//=============================================================================
module liveread_tb;

    parameter CLK_PERIOD = 10;
    parameter SETTLE_CYC = 1_000_000;   // 20 ms at 50 MHz
    parameter DRAIN_CYC  =   500_000;   // 10 ms

    logic clk, rstn, link, err;
    logic [15:0] a1, a2;
    logic [7:0]  w1, w2, r1, r2;
    logic        v1, v2, y1, y2, m1, m2;

    Sytembus #(.CLKS_PER_BIT(434), .RESP_TIMEOUT(500000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(a1), .d1_wdata(w1), .d1_rdata(r1),
        .d1_valid(v1), .d1_ready(y1), .d1_mode(m1),
        .d2_addr(a2), .d2_wdata(w2), .d2_rdata(r2),
        .d2_valid(v2), .d2_ready(y2), .d2_mode(m2),
        .rm_rx(link), .rm_tx(link), .br_error(err)
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer frames = 0;
    bit     counting = 0;

    always @(posedge clk)
        if (counting && dut.bridge.u_en && dut.bridge.u_din == 8'hA5)
            frames = frames + 1;

    task automatic cmd(input logic [15:0] ad, input logic [7:0] d, input bit we);
        begin
            @(negedge clk);
            a1 = ad; w1 = d; m1 = we; v1 = 1'b1;
            repeat (SETTLE_CYC) @(posedge clk);
            @(negedge clk); v1 = 1'b0;
            repeat (DRAIN_CYC) @(posedge clk);
        end
    endtask

    initial begin
        rstn = 0; a1='0; w1='0; v1=0; m1=0; a2='0; w2='0; v2=0; m2=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        cmd(16'h9001, 8'h5C, 1'b1);          // seed through the loopback

        frames = 0; counting = 1;
        cmd(16'h9001, 8'h00, 1'b0);          // read it back
        counting = 0;

        $display("");
        $display("=== ONE console far READ, far board ANSWERING (loopback) ===");
        $display("  REQUEST frames put on the wire : %0d", frames);
        $display("  read value returned            : %02X (expect 5C)", r1);
        $display("  br_error                       : %0d (expect 0)", err);
        $display("");
        $finish;
    end

    initial begin #80_000_000; $display("liveread_tb timed out"); $finish; end
endmodule
