`timescale 1ns/1ps
//=============================================================================
// stress_tb
//
// Hunting an intermittent hardware wedge on the split slave.
//
// The JTAG console asserts dvalid, holds it for ~20ms, then drops it. dvalid
// is a LEVEL, so master_port re-issues the transaction continuously, and the
// console drops it at an arbitrary phase of whatever transaction is in flight.
// Every other bench uses fixed, tidy timing and so never lands on the bad
// phase. This one randomises the hold length so dvalid falls on every possible
// cycle of the split handshake.
//
// A wedge shows up as dready never coming back.
//=============================================================================

module stress_tb;

    parameter CLK_PERIOD = 10;
    parameter ITERS      = 300;

    logic clk, rstn;
    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        rm_tx, br_error;

    integer wedges = 0, runs = 0;

    Sytembus #(.CLKS_PER_BIT(4), .RESP_TIMEOUT(3000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(1'b1), .rm_tx(rm_tx), .br_error(br_error)
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // hold dvalid for `hold` cycles then drop it, exactly like the console,
    // and report whether the master ever came back to idle
    task automatic hold_cmd(input int m, input logic [15:0] a,
                            input logic [7:0] d, input bit we, input int hold,
                            output bit wedged);
        int guard;
        begin
            @(negedge clk);
            if (m == 1) begin
                d1_addr=a; d1_wdata=d; d1_mode=we; d1_valid=1'b1;
            end else begin
                d2_addr=a; d2_wdata=d; d2_mode=we; d2_valid=1'b1;
            end
            repeat (hold) @(posedge clk);
            @(negedge clk);
            if (m == 1) d1_valid = 1'b0; else d2_valid = 1'b0;

            // give it a very generous window to finish and return to idle
            wedged = 1'b1;
            for (guard = 0; guard < 4000; guard++) begin
                @(posedge clk);
                if (m == 1 ? d1_ready : d2_ready) begin wedged = 1'b0; break; end
            end
        end
    endtask

    bit w;
    int h, i;

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        $display("\n=== S3 split slave, dvalid dropped at every phase ===");
        for (i = 0; i < ITERS; i++) begin
            h = 20 + (i % 120);            // sweep the drop phase
            hold_cmd(1, 16'h2A55, 8'h5A, 1'b0, h, w);   // READ, splits
            runs++;
            if (w) begin
                wedges++;
                $display("  WEDGE  M1 read  hold=%0d cycles  (iteration %0d)", h, i);
                // recover so the sweep can continue
                rstn = 0; repeat (4) @(posedge clk); rstn = 1; repeat (4) @(posedge clk);
            end
        end

        $display("\n=== same on master 2 ===");
        for (i = 0; i < ITERS; i++) begin
            h = 20 + (i % 120);
            hold_cmd(2, 16'h2777, 8'h5A, 1'b0, h, w);
            runs++;
            if (w) begin
                wedges++;
                $display("  WEDGE  M2 read  hold=%0d cycles  (iteration %0d)", h, i);
                rstn = 0; repeat (4) @(posedge clk); rstn = 1; repeat (4) @(posedge clk);
            end
        end

        $display("\n=== S3 writes, same phase sweep ===");
        for (i = 0; i < ITERS; i++) begin
            h = 20 + (i % 120);
            hold_cmd(1, 16'h2111, 8'h33, 1'b1, h, w);
            runs++;
            if (w) begin
                wedges++;
                $display("  WEDGE  M1 write hold=%0d cycles  (iteration %0d)", h, i);
                rstn = 0; repeat (4) @(posedge clk); rstn = 1; repeat (4) @(posedge clk);
            end
        end

        // the console's real pattern: write, then read back, with LONG holds
        // so master_port re-issues each transaction ~100 times
        $display("\n=== console pattern: w then r on S3, long holds ===");
        for (i = 0; i < 60; i++) begin
            logic [7:0] want;
            h = 1500 + (i * 37) % 900;     // long, and phase varying
            want = 8'h40 + i[7:0];
            hold_cmd(1, 16'h2A55, want, 1'b1, h, w);
            runs++;
            if (w) begin
                wedges++;
                $display("  WEDGE  on the WRITE, hold=%0d (iter %0d)", h, i);
                rstn=0; repeat(4) @(posedge clk); rstn=1; repeat(4) @(posedge clk);
            end else begin
                hold_cmd(1, 16'h2A55, 8'h00, 1'b0, h, w);
                runs++;
                if (w) begin
                    wedges++;
                    $display("  WEDGE  on the READ, hold=%0d (iter %0d)", h, i);
                    rstn=0; repeat(4) @(posedge clk); rstn=1; repeat(4) @(posedge clk);
                end else if (d1_rdata !== want) begin
                    wedges++;
                    $display("  BAD DATA  read %02h wanted %02h, hold=%0d (iter %0d)",
                             d1_rdata, want, h, i);
                end
            end
        end

        $display("\n=====================================================");
        $display("  %0d wedges/bad in %0d transactions", wedges, runs);
        $display("=====================================================\n");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("stress_tb global timeout");
        $finish;
    end

endmodule
