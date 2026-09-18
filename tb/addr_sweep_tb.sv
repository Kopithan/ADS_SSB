`timescale 1ns/1ps
//=============================================================================
// addr_sweep_tb
//
// Write-then-read every boundary address of all three slaves, from BOTH
// masters, and print a pass/fail table. Answers one question directly:
// is any address inside a slave unwritable?
//
// Expected, from the parameters in Sytembus.sv:
//   S1  ADDR_WIDTH 11, MEM_SIZE 2048  -> 0x0000-0x07FF good,
//                                        0x0800-0x0FFF is the ALIAS HOLE:
//                                        the slave shifts 11 address bits
//                                        while the master sends 12, so the
//                                        transfer desyncs.
//   S2  ADDR_WIDTH 12, MEM_SIZE 4096  -> 0x1000-0x1FFF all good
//   S3  ADDR_WIDTH 12, MEM_SIZE 4096  -> 0x2000-0x2FFF all good, splits on read
//=============================================================================

module addr_sweep_tb;

    parameter CLK_PERIOD = 10;

    logic clk, rstn;
    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        rm_tx, br_error;

    integer good = 0, bad = 0;

    Sytembus #(.CLKS_PER_BIT(4), .RESP_TIMEOUT(3000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(1'b1), .rm_tx(rm_tx), .br_error(br_error)
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    task automatic m1_cmd(input logic [15:0] a, input logic [7:0] d,
                          input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            while (!d1_ready) @(negedge clk);
            d1_addr=a; d1_wdata=d; d1_mode=we; d1_valid=1'b1;
            @(negedge clk); d1_valid=1'b0; @(negedge clk);
            while (!d1_ready) @(negedge clk);
            rd = d1_rdata;
        end
    endtask

    task automatic m2_cmd(input logic [15:0] a, input logic [7:0] d,
                          input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            while (!d2_ready) @(negedge clk);
            d2_addr=a; d2_wdata=d; d2_mode=we; d2_valid=1'b1;
            @(negedge clk); d2_valid=1'b0; @(negedge clk);
            while (!d2_ready) @(negedge clk);
            rd = d2_rdata;
        end
    endtask

    // write a value, read it back, print the verdict
    task automatic probe_addr(input int m, input logic [15:0] a,
                              input logic [7:0] d, input string note);
        logic [7:0] rd;
        begin
            if (m == 1) begin m1_cmd(a, d, 1'b1, rd); m1_cmd(a, 8'h00, 1'b0, rd); end
            else        begin m2_cmd(a, d, 1'b1, rd); m2_cmd(a, 8'h00, 1'b0, rd); end
            if (rd === d) begin
                good = good + 1;
                $display("  M%0d  0x%04X  wrote %02h  read %02h   OK      %s", m, a, d, rd, note);
            end else begin
                bad = bad + 1;
                $display("  M%0d  0x%04X  wrote %02h  read %02h   FAIL    %s", m, a, d, rd, note);
            end
        end
    endtask

    // write different values to two addresses, then read the first back.
    // if it changed, the two addresses are the same physical cell.
    task automatic alias_check(input logic [15:0] a, input logic [15:0] b,
                               input string what);
        logic [7:0] rd;
        begin
            m1_cmd(a, 8'hAA, 1'b1, rd);
            m1_cmd(b, 8'hBB, 1'b1, rd);
            m1_cmd(a, 8'h00, 1'b0, rd);
            if (rd === 8'hBB)
                $display("  %-36s ALIASED   both are one cell", what);
            else if (rd === 8'hAA)
                $display("  %-36s separate  independent cells", what);
            else
                $display("  %-36s ?? read %02h", what, rd);
        end
    endtask

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        $display("\n  master addr    wrote  read       verdict  note");
        $display("  ----------------------------------------------------------------");

        $display("\n--- SLAVE 1, 2K, no split ---");
        probe_addr(1, 16'h0000, 8'h11, "bottom");
        probe_addr(1, 16'h0001, 8'h12, "");
        probe_addr(1, 16'h0400, 8'h13, "middle");
        probe_addr(1, 16'h07FF, 8'h14, "top of the 2K");
        probe_addr(1, 16'h0800, 8'h15, "<- alias hole starts here");
        probe_addr(1, 16'h0FFF, 8'h16, "<- alias hole");

        $display("\n--- SLAVE 2, 4K, no split ---");
        probe_addr(1, 16'h1000, 8'h21, "bottom");
        probe_addr(1, 16'h1001, 8'h22, "");
        probe_addr(1, 16'h1800, 8'h23, "middle");
        probe_addr(1, 16'h1FFF, 8'h24, "top of the 4K");

        $display("\n--- SLAVE 3, 4K, SPLIT capable ---");
        probe_addr(1, 16'h2000, 8'h31, "bottom");
        probe_addr(1, 16'h2001, 8'h32, "the one that failed on hardware");
        probe_addr(1, 16'h27FF, 8'h33, "old bridge/BRAM boundary - 1");
        probe_addr(1, 16'h2800, 8'h34, "old bridge/BRAM boundary");
        probe_addr(1, 16'h2A55, 8'h35, "");
        probe_addr(1, 16'h2FFF, 8'h36, "top of the 4K");

        $display("\n--- SLAVE 3 again, from MASTER 2 ---");
        probe_addr(2, 16'h2000, 8'h41, "bottom");
        probe_addr(2, 16'h2001, 8'h42, "");
        probe_addr(2, 16'h27FF, 8'h43, "");
        probe_addr(2, 16'h2800, 8'h44, "");
        probe_addr(2, 16'h2FFF, 8'h45, "top of the 4K");

        $display("\n  ----------------------------------------------------------------");
        $display("  %0d addresses good, %0d bad", good, bad);

        $display("\n--- aliasing: do two addresses share one physical cell? ---");
        alias_check(16'h0000, 16'h0800, "S1 0x0000 vs 0x0800");
        alias_check(16'h0000, 16'h0001, "S1 0x0000 vs 0x0001 (control)");
        alias_check(16'h1000, 16'h1800, "S2 0x1000 vs 0x1800");
        alias_check(16'h2000, 16'h2800, "S3 0x2000 vs 0x2800");
        $display("");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("FAIL - addr_sweep_tb timed out");
        $finish;
    end

endmodule
