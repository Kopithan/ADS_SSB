`timescale 1ns/1ps
//=============================================================================
// floodcheck_tb
//
// The console holds dvalid for SETTLE milliseconds and dvalid is a LEVEL, so
// master_port re-issues the transaction for the whole window. For a local
// slave that is harmless. For a FAR access every re-issue is another frame
// put on the wire.
//
// This bench runs at the real hardware numbers - CLKS_PER_BIT 434 (115200
// baud at 50 MHz) and a 20 ms held dvalid - and simply counts how many
// REQUEST frames leave the board for ONE console command.
//=============================================================================

module floodcheck_tb;

    parameter CLK_PERIOD = 10;
    parameter SETTLE_CYC = 1_000_000;   // 20 ms at 50 MHz
    parameter DRAIN_CYC  =   500_000;   // 10 ms

    logic clk, rstn;
    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        rm_tx, br_error;

    Sytembus #(.CLKS_PER_BIT(434), .RESP_TIMEOUT(500000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(1'b1), .rm_tx(rm_tx), .br_error(br_error)   // far board silent
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer bytes = 0, frames = 0;
    bit     counting = 0;
    bit     lb_done  = 0;

    always @(posedge clk) begin
        if (counting && dut.bridge.u_en) begin
            bytes = bytes + 1;
            if (dut.bridge.u_din == 8'hA5) frames = frames + 1;
        end
    end

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        $display("");
        $display("=== ONE console far WRITE, dvalid held 20 ms, 115200 baud ===");
        bytes = 0; frames = 0; counting = 1;
        @(negedge clk);
        d1_addr = 16'h9001; d1_wdata = 8'h12; d1_mode = 1'b1; d1_valid = 1'b1;
        repeat (SETTLE_CYC) @(posedge clk);
        @(negedge clk);
        d1_valid = 1'b0;
        repeat (DRAIN_CYC) @(posedge clk);
        counting = 0;
        $display("  REQUEST frames put on the wire : %0d", frames);
        $display("  total bytes                    : %0d", bytes);
        $display("  (one console command = %0d copies of the same write)", frames);

        $display("");
        $display("=== ONE console far READ, dvalid held 20 ms, far board silent ===");
        bytes = 0; frames = 0; counting = 1;
        @(negedge clk);
        d1_addr = 16'h9001; d1_wdata = 8'h00; d1_mode = 1'b0; d1_valid = 1'b1;
        repeat (SETTLE_CYC) @(posedge clk);
        @(negedge clk);
        d1_valid = 1'b0;
        repeat (DRAIN_CYC) @(posedge clk);
        counting = 0;
        $display("  REQUEST frames put on the wire : %0d", frames);
        $display("  total bytes                    : %0d", bytes);
        $display("");
        wait (lb_done);
        $finish;
    end

    initial begin #60_000_000; $display("floodcheck_tb timed out"); $finish; end

    // ------------------------------------------------------------------
    // second board, rm_tx looped back to rm_rx, so far accesses actually
    // get answered. This is the LIVE case: a read completes in about a
    // millisecond instead of waiting out the 10 ms timeout, so the master
    // re-issues it far more often.
    // ------------------------------------------------------------------
    logic        lb_link, lb_err;
    logic [15:0] e1_addr, e2_addr;
    logic [7:0]  e1_wdata, e2_wdata, e1_rdata, e2_rdata;
    logic        e1_valid, e2_valid, e1_ready, e2_ready, e1_mode, e2_mode;

    Sytembus #(.CLKS_PER_BIT(434), .RESP_TIMEOUT(500000)) live (
        .clk(clk), .rstn(rstn),
        .d1_addr(e1_addr), .d1_wdata(e1_wdata), .d1_rdata(e1_rdata),
        .d1_valid(e1_valid), .d1_ready(e1_ready), .d1_mode(e1_mode),
        .d2_addr(e2_addr), .d2_wdata(e2_wdata), .d2_rdata(e2_rdata),
        .d2_valid(e2_valid), .d2_ready(e2_ready), .d2_mode(e2_mode),
        .rm_rx(lb_link), .rm_tx(lb_link), .br_error(lb_err)
    );

    integer lb_frames = 0;
    bit     lb_count  = 0;

    always @(posedge clk)
        if (lb_count && live.bridge.u_en && live.bridge.u_din == 8'hA5)
            lb_frames = lb_frames + 1;

    initial begin
        e1_addr='0; e1_wdata='0; e1_valid=0; e1_mode=0;
        e2_addr='0; e2_wdata='0; e2_valid=0; e2_mode=0;
        wait (rstn === 1'b1);
        repeat (20) @(posedge clk);

        // seed the location through the loopback, then read it back
        @(negedge clk);
        e1_addr = 16'h9001; e1_wdata = 8'h5C; e1_mode = 1'b1; e1_valid = 1'b1;
        repeat (SETTLE_CYC) @(posedge clk);
        @(negedge clk); e1_valid = 1'b0;
        repeat (DRAIN_CYC) @(posedge clk);

        lb_frames = 0; lb_count = 1;
        @(negedge clk);
        e1_addr = 16'h9001; e1_wdata = 8'h00; e1_mode = 1'b0; e1_valid = 1'b1;
        repeat (SETTLE_CYC) @(posedge clk);
        @(negedge clk); e1_valid = 1'b0;
        repeat (DRAIN_CYC) @(posedge clk);
        lb_count = 0;
        $display("=== ONE console far READ, far board ANSWERING (loopback) ===");
        $display("  REQUEST frames put on the wire : %0d", lb_frames);
        $display("  read value returned            : %02X (expect 5C)", e1_rdata);
        $display("");
        lb_done = 1;
    end
endmodule
