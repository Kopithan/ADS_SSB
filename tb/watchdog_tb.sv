`timescale 1ns/1ps
//=============================================================================
// watchdog_tb
//
// RDATA and SPLIT are the only master_port states with no counter of their
// own, so a lost svalid or a lost split reconnect used to hang the master
// forever and take the whole bus down with it - the board needed KEY[0].
//
// This bench starves the master deliberately and proves the watchdog gets it
// back to IDLE on its own. STUCK_TIMEOUT is shrunk so the test runs quickly.
//=============================================================================

module watchdog_tb;

    parameter CLK_PERIOD = 10;
    parameter STUCK      = 200;    // shrunk from the 2,000,000 default

    logic clk, rstn;
    logic [7:0]  dwdata, drdata;
    logic [15:0] daddr;
    logic        dvalid, dready, dmode;
    logic        mrdata, mwdata, mmode, mvalid, svalid;
    logic        mbreq, mbgrant, msplit, ack;

    integer errors = 0, checks = 0;

    master_port #(.STUCK_TIMEOUT(STUCK)) dut (
        .clk(clk), .rstn(rstn),
        .dwdata(dwdata), .drdata(drdata), .daddr(daddr),
        .dvalid(dvalid), .dready(dready), .dmode(dmode),
        .mrdata(mrdata), .mwdata(mwdata), .mmode(mmode),
        .mvalid(mvalid), .svalid(svalid),
        .mbreq(mbreq), .mbgrant(mbgrant), .ack(ack), .msplit(msplit)
    );

    // a split capable slave port on its own, with the same shrunk watchdog
    logic        s_rstn;
    logic [7:0]  s_memrdata, s_memwdata;
    logic [11:0] s_memaddr;
    logic        s_memwen, s_memren, s_swdata, s_srdata, s_smode;
    logic        s_mvalid, s_split_grant, s_svalid, s_sready, s_ssplit;

    slave_port #(.SPLIT_EN(1), .STUCK_TIMEOUT(STUCK)) sdut (
        .clk(clk), .rstn(s_rstn),
        .smemrdata(s_memrdata), .rvalid(1'b1),
        .smemwen(s_memwen), .smemren(s_memren),
        .smemaddr(s_memaddr), .smemwdata(s_memwdata),
        .swdata(s_swdata), .srdata(s_srdata), .smode(s_smode),
        .mvalid(s_mvalid), .split_grant(s_split_grant),
        .svalid(s_svalid), .sready(s_sready), .ssplit(s_ssplit)
    );

    // shift 12 address bits in as a READ, which takes the port through
    // SREADY -> SPLIT -> WAIT, where it then sits waiting for split_grant
    task automatic drive_slave_read;
        integer k;
        begin
            @(negedge clk);
            s_smode = 1'b0;
            for (k = 0; k < 12; k++) begin
                s_swdata = k[0]; s_mvalid = 1'b1;
                @(negedge clk);
            end
            s_mvalid = 1'b0;
        end
    endtask

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    task automatic check(input logic cond, input string msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                $display("  FAIL %s", msg);
                errors = errors + 1;
            end else
                $display("  ok   %s", msg);
        end
    endtask

    // start a read and walk the master as far as RDATA, then stop feeding it
    task automatic start_read;
        begin
            @(negedge clk);
            while (!dready) @(negedge clk);
            daddr = 16'h2A55; dmode = 1'b0; dvalid = 1'b1;
            @(negedge clk); dvalid = 1'b0;
            mbgrant = 1'b1;                 // grant the bus
            repeat (6) @(negedge clk);
            ack = 1'b1;                     // decoder acks
            @(negedge clk); ack = 1'b0;
            repeat (14) @(negedge clk);     // let it shift the address out
        end
    endtask

    initial begin
        rstn = 0;
        daddr='0; dwdata='0; dvalid=0; dmode=0;
        mrdata=0; svalid=0; mbgrant=0; msplit=0; ack=0;
        s_rstn=0; s_memrdata='0; s_swdata=0; s_smode=0; s_mvalid=0; s_split_grant=0;
        repeat (5) @(posedge clk); rstn = 1; repeat (5) @(posedge clk);

        $display("\n=== 1. RDATA starved of svalid ===");
        start_read();
        svalid = 1'b0;                       // never answer
        check(!dready, "master is busy in RDATA");
        repeat (STUCK + 60) @(posedge clk);
        check(dready, "watchdog returned the master to IDLE");

        $display("\n=== 2. SPLIT with the reconnect never granted ===");
        rstn = 0; repeat (4) @(posedge clk); rstn = 1; repeat (4) @(posedge clk);
        mbgrant = 1'b0; msplit = 1'b0; svalid = 1'b0;
        start_read();
        msplit  = 1'b1;                      // slave splits
        @(negedge clk);
        mbgrant = 1'b0;                      // and the bus is never given back
        check(!dready, "master is parked in SPLIT");
        repeat (STUCK + 60) @(posedge clk);
        check(dready, "watchdog returned the master to IDLE");

        $display("\n=== 3. a normal read still completes, watchdog must not fire ===");
        rstn = 0; repeat (4) @(posedge clk); rstn = 1; repeat (4) @(posedge clk);
        msplit = 1'b0;
        start_read();
        begin
            integer i;
            for (i = 0; i < 8; i++) begin
                @(negedge clk); svalid = 1'b1; mrdata = i[0];
                @(negedge clk); svalid = 1'b0;
            end
        end
        repeat (4) @(posedge clk);
        check(dready, "normal read finished on its own");

        $display("\n=== 4. SLAVE parked in WAIT, split_grant never comes ===");
        // this is the case that killed the whole bus on the board: a split
        // slave stuck in WAIT holds sready low, and the arbiter grants nobody
        // until every slave is ready.
        s_rstn = 0; repeat (4) @(posedge clk); s_rstn = 1; repeat (4) @(posedge clk);
        s_split_grant = 1'b0;
        drive_slave_read();
        repeat (8) @(posedge clk);
        check(!s_sready, "slave is busy in SPLIT/WAIT, sready low");
        repeat (STUCK + 60) @(posedge clk);
        check(s_sready, "slave watchdog returned sready on its own");

        $display("\n=====================================================");
        if (errors == 0) $display("PASS - all %0d checks passed", checks);
        else             $display("FAIL - %0d of %0d checks failed", errors, checks);
        $display("=====================================================\n");
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL - watchdog_tb timed out, the watchdog did not fire");
        $finish;
    end

endmodule
