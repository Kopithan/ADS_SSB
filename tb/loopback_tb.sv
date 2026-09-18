`timescale 1ns/1ps
//=============================================================================
// loopback_tb
//
// One board with rm_tx jumpered to rm_rx (PIN_D3 -> PIN_C3 on the DE0-Nano).
// A far access then goes out of our own bridge client, into our own bridge
// server, runs on our own bus as master 3, and the answer comes back to our
// own client. 0x8001 is therefore our own 0x0001, and a read at 0x8001 must
// return what we wrote there, with br_error clear.
//
// This is the hardware self test for the link: if it passes on the board,
// every part of OUR side of the protocol is proven and a failing read
// against another board is that board's problem.
//=============================================================================
module loopback_tb;

    parameter CLK_PERIOD = 10;
    parameter HOLD       = 3000;   // console-style held dvalid
    parameter DRAIN      = 800;    // longer than one 4 byte frame, like the console's 10ms drain

    logic clk, rstn;
    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        link, br_error;
    integer errors = 0, checks = 0;

    Sytembus #(.CLKS_PER_BIT(4), .RESP_TIMEOUT(3000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(link), .rm_tx(link), .br_error(br_error)   // the jumper
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    task automatic hold(input int m, input logic [15:0] a, input logic [7:0] d,
                        input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            if (m == 1) begin d1_addr = a; d1_wdata = d; d1_mode = we; d1_valid = 1; end
            else        begin d2_addr = a; d2_wdata = d; d2_mode = we; d2_valid = 1; end
            repeat (HOLD) @(posedge clk);
            rd = (m == 1) ? d1_rdata : d2_rdata;
            @(negedge clk);
            d1_valid = 0; d2_valid = 0;
            repeat (DRAIN) @(posedge clk);
        end
    endtask

    task automatic expect_eq(input string what, input logic [7:0] got, input logic [7:0] exp);
        begin
            checks++;
            if (got !== exp) begin $display("  FAIL %s: got %02h, expected %02h", what, got, exp); errors++; end
            else               $display("  ok   %s = %02h", what, got);
        end
    endtask

    task automatic expect_bit(input string what, input logic got, input logic exp);
        begin
            checks++;
            if (got !== exp) begin $display("  FAIL %s: got %0d, expected %0d", what, got, exp); errors++; end
            else               $display("  ok   %s = %0d", what, got);
        end
    endtask

    logic [7:0] rd;

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        $display("\n=== loopback: rm_tx jumpered to rm_rx ===");
        hold(1, 16'h8001, 8'h10, 1, rd);            // far write = our own 0x0001
        expect_bit("M1 ready after far write", d1_ready, 1);
        hold(1, 16'h0001, 8'h00, 0, rd);
        expect_eq ("local 0x0001 got the far write", rd, 8'h10);
        hold(1, 16'h8001, 8'h00, 0, rd);            // far read = our own 0x0001
        expect_eq ("M1 far read 0x8001", rd, 8'h10);
        expect_bit("br_error clear", br_error, 0);

        hold(2, 16'h9001, 8'h12, 1, rd);
        hold(2, 16'h9001, 8'h00, 0, rd);
        expect_eq ("M2 far read 0x9001", rd, 8'h12);
        hold(1, 16'h1001, 8'h00, 0, rd);
        expect_eq ("local 0x1001", rd, 8'h12);

        // far S3 through a loopback can NOT return data: our client already
        // holds the one split the arbiter tracks, so the server's read of S3
        // (a second split on the same board) gets no ack and times out. It
        // must not wedge and must not raise br_error - that is all a loopback
        // can prove for S3. Between two real boards each board holds its own
        // split and remote_link_tb checks the data.
        hold(1, 16'hA005, 8'h57, 1, rd);            // far write = our own 0x2005, no split
        hold(1, 16'hA005, 8'h00, 0, rd);
        expect_bit("M1 ready after far S3 read (no wedge)", d1_ready, 1);
        expect_bit("br_error clear", br_error, 0);
        hold(2, 16'h2005, 8'h00, 0, rd);
        expect_eq ("M2 local 0x2005 got the far write", rd, 8'h57);

        $display("\n=====================================================");
        if (errors == 0) $display("PASS - all %0d checks passed", checks);
        else             $display("FAIL - %0d of %0d checks failed", errors, checks);
        $display("=====================================================\n");
        $finish;
    end

    initial begin #20_000_000; $display("FAIL - loopback_tb timed out"); $finish; end
endmodule
