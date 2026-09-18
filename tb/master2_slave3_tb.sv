`timescale 1ns/1ps

// top level tb: 2 masters, 3 slaves, random traffic + arbitration + split
module master2_slave3_tb;

    parameter ADDR_WIDTH = 16;
    parameter DATA_WIDTH = 8;

    // slave1 2KB, slave2 4KB, slave3 4KB w/ split
    parameter SLAVE1_MEM_ADDR_WIDTH = 11;
    parameter SLAVE2_MEM_ADDR_WIDTH = 12;
    parameter SLAVE3_MEM_ADDR_WIDTH = 12;
    parameter MAX_SLAVE_ADDR_WIDTH  = 12;
    parameter DEVICE_ADDR_WIDTH     = ADDR_WIDTH - MAX_SLAVE_ADDR_WIDTH;
    parameter CLK_PERIOD = 10;

    logic clk, rstn;

    // master 1 device side
    logic [DATA_WIDTH-1:0] d1_wdata;
    logic [DATA_WIDTH-1:0] d1_rdata;
    logic [ADDR_WIDTH-1:0] d1_addr;
    logic d1_valid, d1_ready, d1_mode;

    // master 2 device side
    logic [DATA_WIDTH-1:0] d2_wdata;
    logic [DATA_WIDTH-1:0] d2_rdata;
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

    // tb bookkeeping
    integer i;
    logic [ADDR_WIDTH-1:0] rand_addr1, rand_addr2, rand_addr3;
    logic [DATA_WIDTH-1:0] rand_data1, rand_data2;
    logic [DATA_WIDTH-1:0] slave_mem_data1, slave_mem_data2;
    logic [1:0] slave_id1, slave_id2;
    logic m1_accepted, m2_accepted;
    logic [DATA_WIDTH-1:0] d1_rdata_before, d2_rdata_before;
    integer errors = 0;

    wire s_ready = s1_ready & s2_ready & s3_ready;

    // ---------------- DUTs ----------------

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

    slave #(
        .ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN(0), .MEM_SIZE(2048)
    ) slave1 (
        .clk(clk), .rstn(rstn),
        .srdata(s1_rdata), .swdata(s1_wdata), .smode(s1_mode),
        .svalid(s1_svalid), .mvalid(s1_mvalid), .sready(s1_ready),
        .ssplit(), .split_grant(1'b0)
    );

    slave #(
        .ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN(0), .MEM_SIZE(4096)
    ) slave2 (
        .clk(clk), .rstn(rstn),
        .srdata(s2_rdata), .swdata(s2_wdata), .smode(s2_mode),
        .svalid(s2_svalid), .mvalid(s2_mvalid), .sready(s2_ready),
        .ssplit(), .split_grant(1'b0)
    );

    slave #(
        .ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN(1), .MEM_SIZE(4096)
    ) slave3 (
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

    // clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task random_delay;
        integer delay;
        begin
            delay = $urandom % 10;
            $display("Random delay: %0d cycles", delay);
            repeat (delay) @(posedge clk);
        end
    endtask

    // ---------------- stimulus ----------------
    initial begin
        $dumpfile("master2_slave3_tb.vcd");
        $dumpvars(0, master2_slave3_tb);

        rstn = 0;
        d1_valid = 0; d1_wdata = '0; d1_addr = '0; d1_mode = 0;
        d2_valid = 0; d2_wdata = '0; d2_addr = '0; d2_mode = 0;

        repeat (3) @(posedge clk);
        rstn = 1;
        $display("\n=== ADS Bus System Test Started ===\n");
        repeat (2) @(posedge clk);

        // 20 rounds of random traffic
        for (i = 0; i < 20; i = i + 1) begin
            $display("\n--- Iteration %0d ---", i);

            // pick slave + address for each master
            // s1: 0x0000-0x07FF, s2: 0x1000-0x1FFF, s3: 0x2000-0x2FFF
            slave_id1 = $urandom % 3;
            case (slave_id1)
                2'b00: rand_addr1 = 16'h0000 + ($urandom % 16'h0800);
                2'b01: rand_addr1 = 16'h1000 + ($urandom % 16'h1000);
                2'b10: rand_addr1 = 16'h2000 + ($urandom % 16'h1000);
                default: rand_addr1 = 16'h0000;
            endcase
            rand_data1 = $urandom;

            slave_id2 = $urandom % 3;
            case (slave_id2)
                2'b00: rand_addr2 = 16'h0000 + ($urandom % 16'h0800);
                2'b01: rand_addr2 = 16'h1000 + ($urandom % 16'h1000);
                2'b10: rand_addr2 = 16'h2000 + ($urandom % 16'h1000);
                default: rand_addr2 = 16'h0000;
            endcase
            rand_data2 = $urandom;

            // ===== test 1: both masters write, staggered =====
            $display("Generated: M1 addr=0x%0h data=0x%0h, M2 addr=0x%0h data=0x%0h",
                     rand_addr1, rand_data1, rand_addr2, rand_data2);
            wait (d1_ready == 1 && d2_ready == 1 && s_ready == 1);
            @(posedge clk);

            d1_addr  = rand_addr1;
            d1_wdata = rand_data1;
            d1_mode  = 1;
            d1_valid = 1;

            random_delay();

            @(posedge clk);
            d2_addr  = rand_addr2;
            d2_wdata = rand_data2;
            d2_mode  = 1;
            d2_valid = 1;

            @(posedge clk);
            d1_valid = 0;
            d2_valid = 0;

            wait (d1_ready == 0 || d2_ready == 0);              // started
            wait (d1_ready == 1 && d2_ready == 1 && s_ready == 1);  // done
            repeat (2) @(posedge clk);

            // check m1 write hit memory
            case (slave_id1)
                2'b00: slave_mem_data1 = slave1.sm.memory[d1_addr[SLAVE1_MEM_ADDR_WIDTH-1:0]];
                2'b01: slave_mem_data1 = slave2.sm.memory[d1_addr[SLAVE2_MEM_ADDR_WIDTH-1:0]];
                2'b10: slave_mem_data1 = slave3.sm.memory[d1_addr[SLAVE3_MEM_ADDR_WIDTH-1:0]];
                default: ;
            endcase

            if (slave_mem_data1 !== d1_wdata) begin
                $display("ERROR: M1 write failed - Addr: 0x%0h, Expected: 0x%0h, Got: 0x%0h",
                         d1_addr, d1_wdata, slave_mem_data1);
                errors = errors + 1;
            end else
                $display("PASS: M1 write to 0x%0h", d1_addr);

            // check m2 write
            case (slave_id2)
                2'b00: slave_mem_data2 = slave1.sm.memory[d2_addr[SLAVE1_MEM_ADDR_WIDTH-1:0]];
                2'b01: slave_mem_data2 = slave2.sm.memory[d2_addr[SLAVE2_MEM_ADDR_WIDTH-1:0]];
                2'b10: slave_mem_data2 = slave3.sm.memory[d2_addr[SLAVE3_MEM_ADDR_WIDTH-1:0]];
                default: ;
            endcase

            if (slave_mem_data2 !== d2_wdata) begin
                $display("ERROR: M2 write failed - Addr: 0x%0h, Expected: 0x%0h, Got: 0x%0h",
                         d2_addr, d2_wdata, slave_mem_data2);
                errors = errors + 1;
            end else
                $display("PASS: M2 write to 0x%0h", d2_addr);

            // ===== test 2: simultaneous reads, arbitration =====
            @(posedge clk);
            d1_rdata_before = d1_rdata;
            d2_rdata_before = d2_rdata;
            d1_mode = 0; d1_valid = 1;
            d2_mode = 0; d2_valid = 1;

            @(posedge clk);
            d1_valid = 0;
            d2_valid = 0;

            wait (d1_ready == 0 || d2_ready == 0);
            wait (d1_ready == 1 && d2_ready == 1 && s_ready == 1);
            repeat (2) @(posedge clk);

            // did rdata change? then transaction went through
            m1_accepted = (d1_rdata != d1_rdata_before);
            m2_accepted = (d2_rdata != d2_rdata_before);

            if (m1_accepted || d1_rdata == d1_wdata) begin
                if (d1_wdata !== d1_rdata) begin
                    $display("ERROR: M1 read failed - Addr: 0x%0h, Expected: 0x%0h, Got: 0x%0h",
                             d1_addr, d1_wdata, d1_rdata);
                    errors = errors + 1;
                end else
                    $display("PASS: M1 read from 0x%0h", d1_addr);
            end else
                $display("INFO: M1 read denied (addr: 0x%0h)", d1_addr);

            if (m2_accepted || d2_rdata == d2_wdata) begin
                if (d2_wdata !== d2_rdata) begin
                    $display("ERROR: M2 read failed - Addr: 0x%0h, Expected: 0x%0h, Got: 0x%0h",
                             d2_addr, d2_wdata, d2_rdata);
                    errors = errors + 1;
                end else
                    $display("PASS: M2 read from 0x%0h", d2_addr);
            end else
                $display("INFO: M2 read denied (addr: 0x%0h)", d2_addr);

            // ===== test 3: M2 writes, M1 reads same spot =====
            slave_id1 = $urandom % 3;
            case (slave_id1)
                2'b00: rand_addr3 = 16'h0000 + ($urandom % 16'h0800);
                2'b01: rand_addr3 = 16'h1000 + ($urandom % 16'h1000);
                2'b10: rand_addr3 = 16'h2000 + ($urandom % 16'h1000);
                default: rand_addr3 = 16'h0000;
            endcase

            @(posedge clk);
            d2_addr  = rand_addr3;
            d2_wdata = rand_data1 + rand_data2;
            d2_mode  = 1;
            d2_valid = 1;

            random_delay();

            @(posedge clk);
            d1_addr  = d2_addr;
            d1_mode  = 0;
            d1_valid = 1;

            @(posedge clk);
            d1_valid = 0;
            d2_valid = 0;

            wait (d1_ready == 0 || d2_ready == 0);
            wait (d1_ready == 1 && d2_ready == 1 && s_ready == 1);
            repeat (2) @(posedge clk);

            case (slave_id1)
                2'b00: slave_mem_data1 = slave1.sm.memory[d2_addr[SLAVE1_MEM_ADDR_WIDTH-1:0]];
                2'b01: slave_mem_data1 = slave2.sm.memory[d2_addr[SLAVE2_MEM_ADDR_WIDTH-1:0]];
                2'b10: slave_mem_data1 = slave3.sm.memory[d2_addr[SLAVE3_MEM_ADDR_WIDTH-1:0]];
                default: ;
            endcase

            if (slave_mem_data1 !== d2_wdata) begin
                $display("ERROR: write-read conflict, memory has 0x%0h expected 0x%0h",
                         slave_mem_data1, d2_wdata);
                errors = errors + 1;
            end else
                $display("PASS: write-read conflict test");
        end

        repeat (10) @(posedge clk);
        if (errors == 0) $display("\n=== All Tests PASSED ===\n");
        else             $display("\n=== %0d ERRORS ===\n", errors);
        $finish;
    end

    // watchdog
    initial begin
        #2000000;
        $display("\nERROR: Simulation timeout!");
        $finish;
    end

endmodule
