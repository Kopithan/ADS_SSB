`timescale 1ns/1ps

// arbiter unit test: priority, back to back, split scenario
module arbiter_tb;

    logic clk, rstn;
    logic breq1, breq2;
    logic sready1, sready2, sreadysp, ssplit;
    logic bgrant1, bgrant2, msel;
    logic msplit1, msplit2, split_grant;

    integer errors = 0;

    arbiter dut (.*);

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task check(input logic cond, input string msg);
        if (!cond) begin
            $display("ERROR @%0t: %s", $time, msg);
            errors = errors + 1;
        end else
            $display("PASS: %s", msg);
    endtask

    initial begin
        $dumpfile("arbiter_tb.vcd");
        $dumpvars(0, arbiter_tb);

        rstn = 0;
        breq1 = 0; breq2 = 0;
        sready1 = 1; sready2 = 1; sreadysp = 1;
        ssplit = 0;
        repeat (3) @(posedge clk);

        // t0: reset test - everything must be clear while rstn is low
        #1;
        check(!bgrant1 && !bgrant2, "reset: no master granted");
        check(!msel,                "reset: msel clear");
        check(!msplit1 && !msplit2, "reset: no split owner flagged");
        check(!split_grant,         "reset: split_grant clear");

        // async reset: assert it mid request, outputs must clear with no edge
        rstn  = 1;
        breq1 = 1;
        repeat (3) @(posedge clk); #1;
        check(bgrant1, "reset: M1 granted before the async reset test");
        rstn = 0;
        #1;   // no clock edge between here and the check
        check(!bgrant1 && !bgrant2, "reset: async reset drops the grant with no clock edge");
        breq1 = 0;
        rstn  = 1;
        repeat (2) @(posedge clk);

        // t1: only m1 asks
        breq1 = 1;
        repeat (2) @(posedge clk); #1;
        check(bgrant1 && !bgrant2, "M1 alone gets grant");
        breq1 = 0;
        repeat (2) @(posedge clk);

        // t2: only m2 asks
        breq2 = 1;
        repeat (2) @(posedge clk); #1;
        check(bgrant2 && !bgrant1 && msel, "M2 alone gets grant, msel high");
        breq2 = 0;
        repeat (2) @(posedge clk);

        // t3: both ask, m1 should win
        breq1 = 1; breq2 = 1;
        repeat (2) @(posedge clk); #1;
        check(bgrant1 && !bgrant2, "M1 wins when both request");

        // m1 done, m2 should take over
        breq1 = 0;
        repeat (3) @(posedge clk); #1;
        check(bgrant2, "M2 gets bus after M1 releases");
        breq2 = 0;
        repeat (2) @(posedge clk);

        // t4: nobody granted when slaves busy
        sready1 = 0; sready2 = 0; sreadysp = 0;
        breq1 = 1;
        repeat (3) @(posedge clk); #1;
        check(!bgrant1 && !bgrant2, "no grant while slaves busy");
        sready1 = 1; sready2 = 1; sreadysp = 1;
        repeat (2) @(posedge clk); #1;
        check(bgrant1, "grant comes once slaves ready");
        breq1 = 0;
        repeat (2) @(posedge clk);

        // t5: split. m1 owns bus, slave splits, m2 sneaks in, then m1 resumes
        breq1 = 1;
        repeat (2) @(posedge clk); #1;
        check(bgrant1, "M1 granted before split");

        ssplit = 1;                 // slave says wait
        repeat (2) @(posedge clk); #1;
        check(msplit1, "M1 flagged as split owner");
        check(!bgrant1, "bus released on split");

        // m2 can use non-split slaves meanwhile
        breq2 = 1;
        repeat (2) @(posedge clk); #1;
        check(bgrant2, "M2 rides the bus during M1 split");
        breq2 = 0;
        repeat (3) @(posedge clk);

        // slave finishes -> m1 gets it back
        ssplit = 0;
        repeat (2) @(posedge clk); #1;
        check(bgrant1, "M1 re-granted after split ends");

        // split_grant should have pulsed
        wait (split_grant == 1 || errors > 10);
        check(split_grant, "split_grant pulses");
        breq1 = 0;
        repeat (5) @(posedge clk);

        if (errors == 0) $display("\n=== arbiter_tb PASSED ===");
        else             $display("\n=== arbiter_tb: %0d ERRORS ===", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
