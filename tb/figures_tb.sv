`timescale 1ns/1ps

// deterministic scenarios for the report figures.
// each fig gets its own quiet time window, logged to figures.txt
module figures_tb;

    parameter ADDR_WIDTH = 16;
    parameter DATA_WIDTH = 8;
    parameter SLAVE1_MEM_ADDR_WIDTH = 11;
    parameter SLAVE2_MEM_ADDR_WIDTH = 12;
    parameter SLAVE3_MEM_ADDR_WIDTH = 12;
    parameter MAX_SLAVE_ADDR_WIDTH  = 12;
    parameter CLK_PERIOD = 10;

    logic clk, rstn;

    // master device sides
    logic [DATA_WIDTH-1:0] d1_wdata, d1_rdata;
    logic [ADDR_WIDTH-1:0] d1_addr;
    logic d1_valid, d1_ready, d1_mode;
    logic [DATA_WIDTH-1:0] d2_wdata, d2_rdata;
    logic [ADDR_WIDTH-1:0] d2_addr;
    logic d2_valid, d2_ready, d2_mode;

    // bus wires
    logic m1_rdata, m1_wdata, m1_mode, m1_mvalid, m1_svalid;
    logic m1_breq, m1_bgrant, m1_ack, m1_split;
    logic m2_rdata, m2_wdata, m2_mode, m2_mvalid, m2_svalid;
    logic m2_breq, m2_bgrant, m2_ack, m2_split;
    logic s1_rdata, s1_wdata, s1_mode, s1_mvalid, s1_svalid, s1_ready;
    logic s2_rdata, s2_wdata, s2_mode, s2_mvalid, s2_svalid, s2_ready;
    logic s3_rdata, s3_wdata, s3_mode, s3_mvalid, s3_svalid, s3_ready, s3_split;
    logic split_grant;

    integer errors = 0;
    logic [DATA_WIDTH-1:0] rd;

    wire s_ready = s1_ready & s2_ready & s3_ready;

    // ---------------- DUTs (same wiring as top tb) ----------------

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(MAX_SLAVE_ADDR_WIDTH)
    ) master1 (
        .clk(clk), .rstn(rstn),
        .dwdata(d1_wdata), .drdata(d1_rdata), .daddr(d1_addr),
        .dvalid(d1_valid), .dready(d1_ready), .dmode(d1_mode),
        .mrdata(m1_rdata), .mwdata(m1_wdata), .mmode(m1_mode),
        .mvalid(m1_mvalid), .svalid(m1_svalid),
        .mbreq(m1_breq), .mbgrant(m1_bgrant), .ack(m1_ack), .msplit(m1_split)
    );

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(MAX_SLAVE_ADDR_WIDTH)
    ) master2 (
        .clk(clk), .rstn(rstn),
        .dwdata(d2_wdata), .drdata(d2_rdata), .daddr(d2_addr),
        .dvalid(d2_valid), .dready(d2_ready), .dmode(d2_mode),
        .mrdata(m2_rdata), .mwdata(m2_wdata), .mmode(m2_mode),
        .mvalid(m2_mvalid), .svalid(m2_svalid),
        .mbreq(m2_breq), .mbgrant(m2_bgrant), .ack(m2_ack), .msplit(m2_split)
    );

    slave #(.ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
            .SPLIT_EN(0), .MEM_SIZE(2048)) slave1 (
        .clk(clk), .rstn(rstn),
        .srdata(s1_rdata), .swdata(s1_wdata), .smode(s1_mode),
        .svalid(s1_svalid), .mvalid(s1_mvalid), .sready(s1_ready),
        .ssplit(), .split_grant(1'b0)
    );

    slave #(.ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
            .SPLIT_EN(0), .MEM_SIZE(4096)) slave2 (
        .clk(clk), .rstn(rstn),
        .srdata(s2_rdata), .swdata(s2_wdata), .smode(s2_mode),
        .svalid(s2_svalid), .mvalid(s2_mvalid), .sready(s2_ready),
        .ssplit(), .split_grant(1'b0)
    );

    slave #(.ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
            .SPLIT_EN(1), .MEM_SIZE(4096)) slave3 (
        .clk(clk), .rstn(rstn),
        .srdata(s3_rdata), .swdata(s3_wdata), .smode(s3_mode),
        .svalid(s3_svalid), .mvalid(s3_mvalid), .sready(s3_ready),
        .ssplit(s3_split), .split_grant(split_grant)
    );

    bus_m2_s3 #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE1_MEM_ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH),
        .SLAVE2_MEM_ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH),
        .SLAVE3_MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH)
    ) bus (
        .clk(clk), .rstn(rstn),
        .m1_rdata(m1_rdata), .m1_wdata(m1_wdata), .m1_mode(m1_mode),
        .m1_mvalid(m1_mvalid), .m1_svalid(m1_svalid),
        .m1_breq(m1_breq), .m1_bgrant(m1_bgrant), .m1_ack(m1_ack), .m1_split(m1_split),
        .m2_rdata(m2_rdata), .m2_wdata(m2_wdata), .m2_mode(m2_mode),
        .m2_mvalid(m2_mvalid), .m2_svalid(m2_svalid),
        .m2_breq(m2_breq), .m2_bgrant(m2_bgrant), .m2_ack(m2_ack), .m2_split(m2_split),
        .s1_rdata(s1_rdata), .s1_wdata(s1_wdata), .s1_mode(s1_mode),
        .s1_mvalid(s1_mvalid), .s1_svalid(s1_svalid), .s1_ready(s1_ready),
        .s2_rdata(s2_rdata), .s2_wdata(s2_wdata), .s2_mode(s2_mode),
        .s2_mvalid(s2_mvalid), .s2_svalid(s2_svalid), .s2_ready(s2_ready),
        .s3_rdata(s3_rdata), .s3_wdata(s3_wdata), .s3_mode(s3_mode),
        .s3_mvalid(s3_mvalid), .s3_svalid(s3_svalid), .s3_ready(s3_ready),
        .s3_split(s3_split),
        .split_grant(split_grant)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ---------------- figure bookkeeping ----------------
    integer fd;
    integer fig_n = 0;
    time t0;

    task fig_start;
        begin
            repeat (3) @(posedge clk);   // quiet gap so figures don't touch
            t0 = $time;
        end
    endtask

    task fig_done(input string desc);
        begin
            repeat (3) @(posedge clk);
            fig_n = fig_n + 1;
            $fdisplay(fd, "%0d|%0d|%0d|%s", fig_n, t0, $time, desc);
            $display("fig %0d   %6d ns .. %6d ns   %s", fig_n, t0, $time, desc);
        end
    endtask

    // ---------------- driver tasks ----------------
    task m1_write(input [ADDR_WIDTH-1:0] a, input [DATA_WIDTH-1:0] d);
        begin
            wait (d1_ready);
            @(posedge clk);
            d1_addr = a; d1_wdata = d; d1_mode = 1; d1_valid = 1;
            @(posedge clk);
            d1_valid = 0;
            wait (!d1_ready); wait (d1_ready);
            wait (s_ready);           // let the slave land the write
            repeat (2) @(posedge clk);
        end
    endtask

    task m1_read(input [ADDR_WIDTH-1:0] a, output [DATA_WIDTH-1:0] d);
        begin
            wait (d1_ready);
            @(posedge clk);
            d1_addr = a; d1_mode = 0; d1_valid = 1;
            @(posedge clk);
            d1_valid = 0;
            wait (!d1_ready); wait (d1_ready);
            @(posedge clk);
            d = d1_rdata;
        end
    endtask

    task m2_write(input [ADDR_WIDTH-1:0] a, input [DATA_WIDTH-1:0] d);
        begin
            wait (d2_ready);
            @(posedge clk);
            d2_addr = a; d2_wdata = d; d2_mode = 1; d2_valid = 1;
            @(posedge clk);
            d2_valid = 0;
            wait (!d2_ready); wait (d2_ready);
            wait (s_ready);
            repeat (2) @(posedge clk);
        end
    endtask

    task m2_read(input [ADDR_WIDTH-1:0] a, output [DATA_WIDTH-1:0] d);
        begin
            wait (d2_ready);
            @(posedge clk);
            d2_addr = a; d2_mode = 0; d2_valid = 1;
            @(posedge clk);
            d2_valid = 0;
            wait (!d2_ready); wait (d2_ready);
            @(posedge clk);
            d = d2_rdata;
        end
    endtask

    task check(input logic cond, input string msg);
        if (!cond) begin
            $display("  ERROR: %s", msg);
            errors = errors + 1;
        end else
            $display("  PASS: %s", msg);
    endtask

    // ---------------- scenarios ----------------
    initial begin
        fd = $fopen("figures.txt", "w");

        rstn = 0;
        d1_valid = 0; d1_wdata = '0; d1_addr = '0; d1_mode = 0;
        d2_valid = 0; d2_wdata = '0; d2_addr = '0; d2_mode = 0;

        // fig 1: reset, everything idle
        t0 = 0;
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);
        check(d1_ready && d2_ready && s_ready, "reset: all ports idle and ready");
        fig_n = 1;
        $fdisplay(fd, "1|0|%0d|Reset - bus idle, all ports ready", $time);
        $display("fig 1   %6d ns .. %6d ns   Reset - bus idle, all ports ready", 0, $time);

        // fig 2: M1 writes 0x5A to slave1 @0x0155
        fig_start;
        m1_write(16'h0155, 8'h5A);
        check(slave1.sm.memory[11'h155] === 8'h5A, "M1 write 0x5A -> S1[0x155]");
        fig_done("Single master WRITE - M1 writes 0x5A to Slave1 0x0155");

        // fig 3: M1 reads it back
        fig_start;
        m1_read(16'h0155, rd);
        check(rd === 8'h5A, "M1 read back 0x5A from S1");
        fig_done("Single master READ - M1 reads 0x5A back from Slave1");

        // fig 4: slave2 write + read, top of range
        fig_start;
        m1_write(16'h1ABC, 8'h3C);
        m1_read (16'h1ABC, rd);
        check(rd === 8'h3C, "S2[0xABC] write/read 0x3C");
        fig_done("SLAVE 2 (4K) - M1 writes 0x3C to 0x1ABC and reads it back");

        // fig 5: M2 writes slave2 alone
        fig_start;
        m2_write(16'h1FFF, 8'hE7);
        check(slave2.sm.memory[12'hFFF] === 8'hE7, "M2 write 0xE7 -> S2[0xFFF]");
        fig_done("Low priority master - M2 writes 0xE7 to Slave2 0x1FFF");

        // fig 6: decode error, device id 3 doesn't exist -> no ack, timeout
        fig_start;
        m1_write(16'h3000, 8'hAA);
        check(m1_ack === 1'b0, "unmapped 0x3000: no ack, master timed out");
        fig_done("Decode error - unmapped 0x3000, no ack, master times out");

        // fig 7: both masters request together, M1 goes first
        fig_start;
        fork
            m1_write(16'h0020, 8'h11);
            m2_write(16'h1020, 8'h22);
        join
        check(slave1.sm.memory[11'h020] === 8'h11, "arb: M1 write landed");
        check(slave2.sm.memory[12'h020] === 8'h22, "arb: M2 write landed");
        fig_done("Two masters - simultaneous requests, M1 has priority");

        // fig 8: split. M1 reads slave3, bus freed, M2 sneaks a write in
        fig_start;
        m1_write(16'h2050, 8'hBB);     // seed slave3 first
        fork
            m1_read(16'h2050, rd);     // this one splits
            begin
                @(posedge m1_split);   // wait till M1 is parked
                m2_write(16'h0030, 8'h33);
            end
        join
        check(rd === 8'hBB, "split: M1 got 0xBB from S3 after resume");
        check(slave1.sm.memory[11'h030] === 8'h33, "split: M2 used bus in the gap");
        fig_done("SPLIT transaction - M1 split on S3, M2 uses bus, M1 resumes");

        // fig 9: coherency S1, M2 writes then M1 reads
        fig_start;
        m2_write(16'h0100, 8'hC1);
        m1_read (16'h0100, rd);
        check(rd === 8'hC1, "coherency S1: M1 sees M2's 0xC1");
        fig_done("Cross-master coherency on SLAVE 1 - M2 writes, M1 reads");

        // fig 10: coherency S2
        fig_start;
        m2_write(16'h1200, 8'hC2);
        m1_read (16'h1200, rd);
        check(rd === 8'hC2, "coherency S2: M1 sees M2's 0xC2");
        fig_done("Cross-master coherency on SLAVE 2 - M2 writes, M1 reads");

        // fig 11: coherency S3, read goes through a split
        fig_start;
        m2_write(16'h2300, 8'hC3);
        m1_read (16'h2300, rd);
        check(rd === 8'hC3, "coherency S3 through split: M1 sees 0xC3");
        fig_done("Coherency through a SPLIT - M2 writes S3, M1 reads it back");

        // fig 12: same offset 0x000 in all three slaves, independent memories
        fig_start;
        m1_write(16'h0000, 8'hA1);
        m1_write(16'h1000, 8'hA2);
        m1_write(16'h2000, 8'hA3);
        m1_read (16'h0000, rd); check(rd === 8'hA1, "offset 0: S1 holds 0xA1");
        m1_read (16'h1000, rd); check(rd === 8'hA2, "offset 0: S2 holds 0xA2");
        m1_read (16'h2000, rd); check(rd === 8'hA3, "offset 0: S3 holds 0xA3");
        fig_done("Same offset 0x000 in all 3 slaves - three independent memories");

        $fclose(fd);
        repeat (5) @(posedge clk);
        if (errors == 0) $display("\n=== figures_tb PASSED, %0d figures logged ===", fig_n);
        else             $display("\n=== figures_tb: %0d ERRORS ===", errors);
        $stop;   // stop, not finish - keep the wave window alive
    end

    // watchdog
    initial begin
        #500000;
        $display("ERROR: timeout");
        $stop;
    end

endmodule
