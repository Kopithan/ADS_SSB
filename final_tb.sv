`timescale 1ns/1ps
//=============================================================================
// final_tb - top level verification of Sytembus
//
// Simulates the module that actually gets synthesised (Sytembus), NOT the
// JTAG wrapper Sytembus_top. The wrapper contains an Altera megafunction
// with no simulation model, and has no stimulus of its own.
//
// Covers the four scenarios required by the assignment:
//   (a) reset test
//   (b) one master request
//   (c) two master requests - priority arbitration
//   (d) split transaction viable scenario
// plus a decode-error case and a memory-independence case.
//
// Each scenario gets a quiet gap either side; its time window is written to
// figures.txt so the waveform can be cropped cleanly for report diagrams.
//
// ADDRESS MAP  (device id = addr[15:12])
//   id 0 -> slave1, 2K BRAM           0x0000 - 0x07FF
//   id 1 -> slave2, 4K BRAM           0x1000 - 0x1FFF
//   id 2 -> slave3, bus_bridge_slave  0x2000 - 0x2FFF
//        addr[11] = 1 -> LOCAL BRAM   0x2800 - 0x2FFF   <-- used here
//        addr[11] = 0 -> forwarded over UART, never completes without a
//                        remote board. Do not use those addresses.
//   id 3 -> unmapped, used for the decode-error test
//=============================================================================

module final_tb;

    parameter ADDR_WIDTH = 16;
    parameter DATA_WIDTH = 8;
    parameter CLK_PERIOD = 10;

    logic clk, rstn;

    logic [ADDR_WIDTH-1:0] d1_addr, d2_addr;
    logic [DATA_WIDTH-1:0] d1_wdata, d2_wdata;
    logic [DATA_WIDTH-1:0] d1_rdata, d2_rdata;
    logic d1_valid, d1_ready, d1_mode;
    logic d1_remote, d1_error;
    logic d2_valid, d2_ready, d2_mode;
    logic bs_rx, bs_tx;
    logic rm_rx, rm_tx;

    integer errors = 0;
    logic [DATA_WIDTH-1:0] rd;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    Sytembus #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SLAVE1_MEM_ADDR_WIDTH(11),
        .SLAVE2_MEM_ADDR_WIDTH(12),
        .SLAVE3_MEM_ADDR_WIDTH(12),
        .UART_CLOCKS_PER_PULSE(5208)
    ) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d1_remote(d1_remote), .d1_error(d1_error),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .bs_rx(bs_rx), .bs_tx(bs_tx),
        .rm_rx(rm_rx), .rm_tx(rm_tx)
    );

    wire s_ready = dut.s1_ready & dut.s2_ready & dut.s3_ready;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // reporting helpers
    // (message args are byte vectors, not the string type - ModelSim ASE
    //  does not always accept "input string" in a task)
    //-------------------------------------------------------------------------
    integer fd;
    integer fig_n = 0;
    time    t0;

    task check(input logic cond, input reg [8*64:1] msg);
        begin
            if (!cond) begin
                $display("  ERROR: %0s", msg);
                errors = errors + 1;
            end else begin
                $display("  PASS : %0s", msg);
            end
        end
    endtask

    task fig_start;
        begin
            repeat (4) @(posedge clk);
            t0 = $time;
        end
    endtask

    task fig_done(input reg [8*64:1] desc);
        begin
            repeat (4) @(posedge clk);
            fig_n = fig_n + 1;
            $fdisplay(fd, "%0d|%0d|%0d|%0s", fig_n, t0, $time, desc);
            $display("  [fig %0d]  %0d ns .. %0d ns  %0s", fig_n, t0, $time, desc);
        end
    endtask

    //-------------------------------------------------------------------------
    // bus driver tasks
    //-------------------------------------------------------------------------
    task m1_write(input [ADDR_WIDTH-1:0] a, input [DATA_WIDTH-1:0] d);
        begin
            wait (d1_ready);
            @(posedge clk);
            d1_addr = a; d1_wdata = d; d1_mode = 1'b1; d1_valid = 1'b1;
            @(posedge clk);
            d1_valid = 1'b0;
            wait (!d1_ready);
            wait (d1_ready);
            wait (s_ready);
            repeat (2) @(posedge clk);
        end
    endtask

    task m1_read(input [ADDR_WIDTH-1:0] a, output [DATA_WIDTH-1:0] d);
        begin
            wait (d1_ready);
            @(posedge clk);
            d1_addr = a; d1_mode = 1'b0; d1_valid = 1'b1;
            @(posedge clk);
            d1_valid = 1'b0;
            wait (!d1_ready);
            wait (d1_ready);
            @(posedge clk);
            d = d1_rdata;
        end
    endtask

    task m2_write(input [ADDR_WIDTH-1:0] a, input [DATA_WIDTH-1:0] d);
        begin
            wait (d2_ready);
            @(posedge clk);
            d2_addr = a; d2_wdata = d; d2_mode = 1'b1; d2_valid = 1'b1;
            @(posedge clk);
            d2_valid = 1'b0;
            wait (!d2_ready);
            wait (d2_ready);
            wait (s_ready);
            repeat (2) @(posedge clk);
        end
    endtask

    task m2_read(input [ADDR_WIDTH-1:0] a, output [DATA_WIDTH-1:0] d);
        begin
            wait (d2_ready);
            @(posedge clk);
            d2_addr = a; d2_mode = 1'b0; d2_valid = 1'b1;
            @(posedge clk);
            d2_valid = 1'b0;
            wait (!d2_ready);
            wait (d2_ready);
            @(posedge clk);
            d = d2_rdata;
        end
    endtask

    //-------------------------------------------------------------------------
    // scenarios
    //-------------------------------------------------------------------------
    initial begin
        fd = $fopen("figures.txt", "w");

        bs_rx     = 1'b1;              // uart idle, no remote board attached
        rm_rx     = 1'b1;              // remote link idle, no far board here
        d1_remote = 1'b0;              // this tb only exercises local access
        rstn     = 1'b0;
        d1_valid = 1'b0; d1_wdata = 8'h00; d1_addr = 16'h0000; d1_mode = 1'b0;
        d2_valid = 1'b0; d2_wdata = 8'h00; d2_addr = 16'h0000; d2_mode = 1'b0;

        //---------------------------------------------------------------------
        // (a) RESET TEST
        //---------------------------------------------------------------------
        $display("\n--- (a) reset test ---");
        t0 = 0;
        repeat (5) @(posedge clk);

        check(dut.m1_bgrant    === 1'b0, "reset: M1 not granted");
        check(dut.m2_bgrant    === 1'b0, "reset: M2 not granted");
        check(dut.m1_breq      === 1'b0, "reset: M1 not requesting");
        check(dut.m2_breq      === 1'b0, "reset: M2 not requesting");
        check(dut.m1_split     === 1'b0, "reset: M1 split flag clear");
        check(dut.m2_split     === 1'b0, "reset: M2 split flag clear");
        check(dut.split_grant  === 1'b0, "reset: split_grant clear");

        @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        check(d1_ready && d2_ready, "post-reset: both masters idle and ready");
        check(s_ready,              "post-reset: all three slaves ready");

        fig_n = 1;
        $fdisplay(fd, "1|0|%0d|Reset - grants low, masters idle, slaves ready", $time);
        $display("  [fig 1]  0 ns .. %0d ns  Reset", $time);

        //---------------------------------------------------------------------
        // (b) ONE MASTER REQUEST
        //---------------------------------------------------------------------
        $display("\n--- (b) single master request ---");

        fig_start;
        m1_write(16'h0155, 8'h5A);
        check(dut.slave1.sm.memory[11'h155] === 8'h5A, "M1 write 0x5A to S1[0x155]");
        m1_read(16'h0155, rd);
        check(rd === 8'h5A, "M1 read back 0x5A from S1");
        fig_done("Single master - M1 write then read, Slave1 0x0155");

        fig_start;
        m1_write(16'h1ABC, 8'h3C);
        check(dut.slave2.sm.memory[12'hABC] === 8'h3C, "M1 write 0x3C to S2[0xABC]");
        m1_read(16'h1ABC, rd);
        check(rd === 8'h3C, "M1 read back 0x3C from S2");
        fig_done("Single master - M1 write then read, Slave2 0x1ABC");

        fig_start;
        m2_write(16'h1FFF, 8'hE7);
        check(dut.slave2.sm.memory[12'hFFF] === 8'hE7, "M2 write 0xE7 to S2[0xFFF]");
        m2_read(16'h1FFF, rd);
        check(rd === 8'hE7, "M2 read back 0xE7 from S2");
        fig_done("Single master - M2 alone, write then read, Slave2 0x1FFF");

        fig_start;
        m1_write(16'h2A55, 8'h9D);
        check(dut.slave3_bridge.local_mem.memory[11'h255] === 8'h9D,
              "M1 write 0x9D to S3 local[0x255]");
        fig_done("Single master - M1 write to Slave3 local BRAM 0x2A55");

        //---------------------------------------------------------------------
        // (c) TWO MASTER REQUESTS
        //---------------------------------------------------------------------
        $display("\n--- (c) two masters, simultaneous request ---");

        fig_start;
        wait (d1_ready && d2_ready && s_ready);
        @(posedge clk);
        d1_addr = 16'h0020; d1_wdata = 8'h11; d1_mode = 1'b1; d1_valid = 1'b1;
        d2_addr = 16'h1020; d2_wdata = 8'h22; d2_mode = 1'b1; d2_valid = 1'b1;
        @(posedge clk);
        d1_valid = 1'b0; d2_valid = 1'b0;

        wait (dut.m1_bgrant || dut.m2_bgrant);
        check(dut.m1_bgrant && !dut.m2_bgrant, "arbitration: M1 granted first");

        wait (d1_ready && d2_ready && s_ready);
        repeat (2) @(posedge clk);
        check(dut.slave1.sm.memory[11'h020] === 8'h11, "arbitration: M1 write landed");
        check(dut.slave2.sm.memory[12'h020] === 8'h22, "arbitration: M2 write landed");
        fig_done("Two masters - simultaneous request, M1 priority, both complete");

        fig_start;
        m2_write(16'h0100, 8'hC1);
        m1_read (16'h0100, rd);
        check(rd === 8'hC1, "coherency: M1 reads M2's 0xC1 from S1");
        fig_done("Two masters - cross-master coherency on Slave1 0x0100");

        //---------------------------------------------------------------------
        // (d) SPLIT TRANSACTION
        //---------------------------------------------------------------------
        $display("\n--- (d) split transaction ---");

        m1_write(16'h2A50, 8'hBB);      // seed slave3 local

        fig_start;
        fork
            m1_read(16'h2A50, rd);      // splits: slave_port SPLIT_EN = 1
            begin
                @(posedge dut.m1_split);
                check(!dut.m1_bgrant, "split: bus released while M1 parked");
                m2_write(16'h0030, 8'h33);
                check(dut.slave1.sm.memory[11'h030] === 8'h33,
                      "split: M2 used the bus during M1 split");
            end
        join
        check(rd === 8'hBB, "split: M1 received 0xBB after resume");
        fig_done("SPLIT - M1 splits on Slave3, M2 uses bus, M1 resumes");

        //---------------------------------------------------------------------
        // decode error
        //---------------------------------------------------------------------
        $display("\n--- decode error ---");
        fig_start;
        m1_write(16'h3000, 8'hAA);
        check(dut.m1_ack === 1'b0, "unmapped 0x3000: no ack");
        check(d1_ready,            "unmapped 0x3000: master recovered to IDLE");
        fig_done("Decode error - unmapped device id 3, no ack, master times out");

        //---------------------------------------------------------------------
        // three independent memories at the same offset
        //---------------------------------------------------------------------
        fig_start;
        m1_write(16'h0000, 8'hA1);
        m1_write(16'h1000, 8'hA2);
        m1_write(16'h2800, 8'hA3);      // slave3 local, offset 0
        m1_read (16'h0000, rd); check(rd === 8'hA1, "offset 0: S1 holds 0xA1");
        m1_read (16'h1000, rd); check(rd === 8'hA2, "offset 0: S2 holds 0xA2");
        m1_read (16'h2800, rd); check(rd === 8'hA3, "offset 0: S3 holds 0xA3");
        fig_done("Same offset in all 3 slaves - independent memories");

        //---------------------------------------------------------------------
        $fclose(fd);
        repeat (5) @(posedge clk);
        if (errors == 0)
            $display("\n=== final_tb PASSED - %0d figures logged ===\n", fig_n);
        else
            $display("\n=== final_tb: %0d ERRORS ===\n", errors);
        $stop;
    end

    // watchdog
    initial begin
        #1000000;
        $display("\nERROR: simulation timeout - a transaction never completed.");
        $display("       A Slave3 access in 0x2000-0x27FF waits forever for a");
        $display("       UART reply. Use 0x2800-0x2FFF for the local BRAM.");
        $stop;
    end

endmodule