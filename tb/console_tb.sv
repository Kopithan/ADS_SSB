`timescale 1ns/1ps
//=============================================================================
// console_tb
//
// Drives Sytembus the way issp_console.tcl drives it over JTAG, which is NOT
// how the other benches drive it:
//
//   the console sets a valid bit and HOLDS it for SETTLE milliseconds, then
//   clears it. dvalid is a level, so master_port repeats the transaction over
//   and over for the whole window. The other benches pulse dvalid for one
//   cycle, so back to back re-issue is never exercised.
//
// This bench reproduces the hardware access pattern at simulation speed.
//=============================================================================

module console_tb;

    parameter CLK_PERIOD = 10;
    parameter HOLD       = 400;   // cycles dvalid is held, stands in for SETTLE
    parameter DRAIN      = 40;    // cycles after dropping it

    logic clk, rstn;

    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        rm_tx, br_error;

    integer errors = 0;
    integer checks = 0;

    Sytembus #(
        .CLKS_PER_BIT(4), .RESP_TIMEOUT(3000)
    ) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(1'b1), .rm_tx(rm_tx), .br_error(br_error)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // exactly what bus_write / bus_read do in the console
    task automatic m1_hold(input logic [15:0] a, input logic [7:0] d,
                           input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            d1_addr = a; d1_wdata = d; d1_mode = we; d1_valid = 1'b1;
            repeat (HOLD) @(posedge clk);
            rd = d1_rdata;                 // sampled while still looping
            @(negedge clk);
            d1_valid = 1'b0;
            repeat (DRAIN) @(posedge clk);
        end
    endtask

    task automatic m2_hold(input logic [15:0] a, input logic [7:0] d,
                           input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            d2_addr = a; d2_wdata = d; d2_mode = we; d2_valid = 1'b1;
            repeat (HOLD) @(posedge clk);
            rd = d2_rdata;
            @(negedge clk);
            d2_valid = 1'b0;
            repeat (DRAIN) @(posedge clk);
        end
    endtask

    task automatic expect_eq(input string what,
                             input logic [7:0] got, input logic [7:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                $display("  FAIL %s: got %02h, expected %02h", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok   %s = %02h", what, got);
        end
    endtask

    task automatic expect_ready(input string what);
        begin
            checks = checks + 1;
            if (!d1_ready) begin
                $display("  FAIL %s: M1 WEDGED, dready still low", what);
                errors = errors + 1;
            end else
                $display("  ok   %s: M1 not wedged", what);
        end
    endtask

    logic [7:0] rd;

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk);
        rstn = 1;
        repeat (10) @(posedge clk);

        $display("\n=== console style access, valid held high ===");

        m1_hold(16'h0001, 8'h56, 1'b1, rd);
        expect_ready("after S1 write");
        m1_hold(16'h0001, 8'h00, 1'b0, rd);
        expect_eq("S1 0x0001 read back", rd, 8'h56);

        m1_hold(16'h1001, 8'h45, 1'b1, rd);
        expect_ready("after S2 write");
        m1_hold(16'h1001, 8'h00, 1'b0, rd);
        expect_eq("S2 0x1001 read back", rd, 8'h45);

        m1_hold(16'h2001, 8'h21, 1'b1, rd);
        expect_ready("after S3 write");
        m1_hold(16'h2001, 8'h00, 1'b0, rd);
        expect_eq("S3 0x2001 read back", rd, 8'h21);

        m1_hold(16'h2A55, 8'h9D, 1'b1, rd);
        m1_hold(16'h2A55, 8'h00, 1'b0, rd);
        expect_eq("S3 0x2A55 read back", rd, 8'h9D);

        $display("\n=== same on master 2 ===");
        m2_hold(16'h2001, 8'h77, 1'b1, rd);
        m2_hold(16'h2001, 8'h00, 1'b0, rd);
        expect_eq("M2 S3 0x2001 read back", rd, 8'h77);

        $display("\n=== FAR read with no far board, dvalid HELD across the timeout ===");
        // this is what the console's startup fingerprint does: r 8100 with valid
        // held for 20ms against a 10ms bridge timeout, so the master re-issues
        // the far read while the bridge is still finishing the previous one.
        // rm_rx is tied high here (pull-up), RESP_TIMEOUT is 3000 cycles.
        begin
            @(negedge clk);
            d1_addr = 16'h8100; d1_wdata = 8'h00; d1_mode = 1'b0; d1_valid = 1'b1;
            repeat (8000) @(posedge clk);      // ~2.5 timeouts worth
            @(negedge clk);
            d1_valid = 1'b0;
            repeat (4000) @(posedge clk);      // let the last one time out
        end
        expect_ready("after held far read");
        m1_hold(16'h2001, 8'h56, 1'b1, rd);
        expect_ready("M1 S3 write after far read");
        m1_hold(16'h2001, 8'h00, 1'b0, rd);
        expect_eq("M1 S3 read after far read", rd, 8'h56);
        m2_hold(16'h2888, 8'h67, 1'b1, rd);
        m2_hold(16'h2888, 8'h00, 1'b0, rd);
        expect_eq("M2 S3 read after far read", rd, 8'h67);

        $display("\n=== bus still alive afterwards ===");
        m1_hold(16'h0001, 8'h00, 1'b0, rd);
        expect_eq("S1 0x0001 still there", rd, 8'h56);
        expect_ready("at end");

        $display("\n=====================================================");
        if (errors == 0) $display("PASS - all %0d checks passed", checks);
        else             $display("FAIL - %0d of %0d checks failed", errors, checks);
        $display("=====================================================\n");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("FAIL - console_tb timed out, something hung");
        $finish;
    end

endmodule
