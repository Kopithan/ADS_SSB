`timescale 1ns/1ps
//=============================================================================
// cycles_tb
//
// Measures how many clock cycles each kind of transaction actually costs, so
// the report can quote real numbers instead of estimates:
//
//   - latency from dvalid asserted to dready back high, per slave, read/write
//   - how long ssplit stays high on an S3 read
//   - how many of those cycles the bus is actually FREE for the other master
//=============================================================================

module cycles_tb;

    parameter CLK_PERIOD = 10;

    logic clk, rstn;
    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        rm_tx, br_error;

    integer cyc = 0;   // free running cycle counter

    Sytembus #(.CLKS_PER_BIT(4), .RESP_TIMEOUT(3000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(1'b1), .rm_tx(rm_tx), .br_error(br_error)
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end
    always_ff @(posedge clk) cyc <= cyc + 1;

    // ssplit high time on the most recent S3 read
    integer split_len = 0, split_run = 0;
    always_ff @(posedge clk) begin
        if (dut.s3_split) begin
            split_run <= split_run + 1;
        end else if (split_run != 0) begin
            split_len <= split_run;
            split_run <= 0;
        end
    end

    // cycles M1 was parked in SPLIT, i.e. cycles the bus was free for others
    integer parked = 0;
    always_ff @(posedge clk) if (dut.m1_split) parked <= parked + 1;

    task automatic timed(input logic [15:0] a, input logic [7:0] d,
                         input bit we, input string what);
        integer t0, t1;
        begin
            @(negedge clk);
            while (!d1_ready) @(negedge clk);
            parked = 0;
            d1_addr=a; d1_wdata=d; d1_mode=we; d1_valid=1'b1;
            t0 = cyc;
            @(negedge clk); d1_valid=1'b0; @(negedge clk);
            while (!d1_ready) @(negedge clk);
            t1 = cyc;
            $display("  %-34s %3d cycles   split held %2d, bus free %2d",
                     what, t1 - t0, split_len, parked);
        end
    endtask

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        $display("\n  transaction                        latency      split detail");
        $display("  ------------------------------------------------------------------");
        timed(16'h0155, 8'h5A, 1'b1, "S1 WRITE  (2K, no split)");
        timed(16'h0155, 8'h00, 1'b0, "S1 READ   (2K, no split)");
        timed(16'h1ABC, 8'h3C, 1'b1, "S2 WRITE  (4K, no split)");
        timed(16'h1ABC, 8'h00, 1'b0, "S2 READ   (4K, no split)");
        timed(16'h2A55, 8'h9D, 1'b1, "S3 WRITE  (4K, SPLIT slave)");
        timed(16'h2A55, 8'h00, 1'b0, "S3 READ   (4K, SPLIT slave)");
        $display("  ------------------------------------------------------------------\n");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL - cycles_tb timed out");
        $finish;
    end

endmodule
