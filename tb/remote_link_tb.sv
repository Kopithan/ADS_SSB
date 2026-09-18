`timescale 1ns/1ps
//=============================================================================
// remote_link_tb
//
// Two complete copies of the bus system with their bridge links crossed:
//   A.rm_tx -> B.rm_rx      B.rm_tx -> A.rm_rx
//
// The link is a bus device now, not a feature of master 1, so the point of
// this bench is that EITHER master on EITHER board can reach ALL THREE slaves
// on the far board, at any offset, with no remote side channel anywhere.
//
// A "cable" mux lets the link be cut mid simulation to prove the timeout.
// A spare uart_rx sits on A's tx line as a byte sniffer so the wire format
// can be checked against the spec byte for byte.
//=============================================================================

module remote_link_tb;

    parameter ADDR_WIDTH            = 16;
    parameter DATA_WIDTH            = 8;
    parameter SLAVE1_MEM_ADDR_WIDTH = 11;
    parameter SLAVE2_MEM_ADDR_WIDTH = 12;
    parameter SLAVE3_MEM_ADDR_WIDTH = 12;
    parameter CLK_PERIOD            = 10;

    // shrunk so this runs in reasonable time
    parameter CLKS_PER_BIT = 4;
    parameter RESP_TIMEOUT = 3000;

    // address map, identical on both boards.
    // dev id = addr[15:12]: 0..2 are the local slaves, 8..10 are the bridge.
    localparam [15:0] L_S1  = 16'h0100;   // local slave1, plain bram
    localparam [15:0] L_S2  = 16'h1000;   // local slave2, plain bram
    localparam [15:0] L_S3  = 16'h2800;   // local slave3, 4K, splits on read
    localparam [15:0] L_S2H = 16'h1FFF;   // local slave2, top of its 4K
    localparam [15:0] L_S1B = 16'h0200;

    localparam [15:0] F_S1  = 16'h8100;   // far slave1  = L_S1  on the other board
    localparam [15:0] F_S2  = 16'h9000;   // far slave2  = L_S2
    localparam [15:0] F_S3  = 16'hA800;   // far slave3  = L_S3
    localparam [15:0] F_S2H = 16'h9FFF;   // far slave2, top of its 4K
    localparam [15:0] F_S1B = 16'h8200;

    logic clk, rstn;
    logic link_up;

    integer errors = 0;
    integer checks = 0;

    // ---------------- board A device ports ----------------
    logic [ADDR_WIDTH-1:0] a1_addr;  logic [DATA_WIDTH-1:0] a1_wdata, a1_rdata;
    logic a1_valid, a1_ready, a1_mode;
    logic [ADDR_WIDTH-1:0] a2_addr;  logic [DATA_WIDTH-1:0] a2_wdata, a2_rdata;
    logic a2_valid, a2_ready, a2_mode;
    logic a_rm_tx, a_err;

    // ---------------- board B device ports ----------------
    logic [ADDR_WIDTH-1:0] b1_addr;  logic [DATA_WIDTH-1:0] b1_wdata, b1_rdata;
    logic b1_valid, b1_ready, b1_mode;
    logic [ADDR_WIDTH-1:0] b2_addr;  logic [DATA_WIDTH-1:0] b2_wdata, b2_rdata;
    logic b2_valid, b2_ready, b2_mode;
    logic b_rm_tx, b_err;

    // the cable. cut it and both ends see idle high.
    wire a_rm_rx = link_up ? b_rm_tx : 1'b1;
    wire b_rm_rx = link_up ? a_rm_tx : 1'b1;

    Sytembus #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE1_MEM_ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH),
        .SLAVE2_MEM_ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH),
        .SLAVE3_MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH),
        .CLKS_PER_BIT(CLKS_PER_BIT), .RESP_TIMEOUT(RESP_TIMEOUT)
    ) boardA (
        .clk(clk), .rstn(rstn),
        .d1_addr(a1_addr), .d1_wdata(a1_wdata), .d1_rdata(a1_rdata),
        .d1_valid(a1_valid), .d1_ready(a1_ready), .d1_mode(a1_mode),
        .d2_addr(a2_addr), .d2_wdata(a2_wdata), .d2_rdata(a2_rdata),
        .d2_valid(a2_valid), .d2_ready(a2_ready), .d2_mode(a2_mode),
        .rm_rx(a_rm_rx), .rm_tx(a_rm_tx),
        .br_error(a_err)
    );

    Sytembus #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .SLAVE1_MEM_ADDR_WIDTH(SLAVE1_MEM_ADDR_WIDTH),
        .SLAVE2_MEM_ADDR_WIDTH(SLAVE2_MEM_ADDR_WIDTH),
        .SLAVE3_MEM_ADDR_WIDTH(SLAVE3_MEM_ADDR_WIDTH),
        .CLKS_PER_BIT(CLKS_PER_BIT), .RESP_TIMEOUT(RESP_TIMEOUT)
    ) boardB (
        .clk(clk), .rstn(rstn),
        .d1_addr(b1_addr), .d1_wdata(b1_wdata), .d1_rdata(b1_rdata),
        .d1_valid(b1_valid), .d1_ready(b1_ready), .d1_mode(b1_mode),
        .d2_addr(b2_addr), .d2_wdata(b2_wdata), .d2_rdata(b2_rdata),
        .d2_valid(b2_valid), .d2_ready(b2_ready), .d2_mode(b2_mode),
        .rm_rx(b_rm_rx), .rm_tx(b_rm_tx),
        .br_error(b_err)
    );

    // ---------------- wire sniffer on A's tx ----------------
    // reuse the known good receiver so the sampling matches exactly
    logic [7:0] snif_byte;
    logic       snif_ready, snif_ready_q;
    logic [7:0] snif_buf [0:15];
    integer     snif_n;
    logic       snif_en;

    uart_rx #(.CLOCKS_PER_PULSE(CLKS_PER_BIT), .DATA_WIDTH(8)) sniffer_a (
        .clk(clk), .rstn(rstn), .rx(a_rm_tx),
        .data_out(snif_byte), .ready(snif_ready)
    );

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            snif_ready_q <= 1'b0;
            snif_n       <= 0;
        end else begin
            snif_ready_q <= snif_ready;
            if (snif_en && snif_ready && !snif_ready_q && snif_n < 16) begin
                snif_buf[snif_n] <= snif_byte;
                snif_n           <= snif_n + 1;
            end
        end
    end

    task automatic snif_start;
        begin
            @(negedge clk);
            snif_n  = 0;
            snif_en = 1'b1;
        end
    endtask

    task automatic snif_check(input string what, input int n,
                              input logic [7:0] e0, e1, e2, e3);
        logic [7:0] exp [0:3];
        integer i;
        begin
            snif_en = 1'b0;
            exp[0]=e0; exp[1]=e1; exp[2]=e2; exp[3]=e3;
            checks = checks + 1;
            if (snif_n != n) begin
                $display("  FAIL %s: saw %0d bytes on the wire, expected %0d", what, snif_n, n);
                errors = errors + 1;
            end else begin
                for (i = 0; i < n; i = i + 1) begin
                    if (snif_buf[i] !== exp[i]) begin
                        $display("  FAIL %s: byte %0d = %02h, expected %02h",
                                 what, i, snif_buf[i], exp[i]);
                        errors = errors + 1;
                    end
                end
                if (n == 4)
                    $display("  wire %s: %02h %02h %02h %02h  OK",
                             what, snif_buf[0], snif_buf[1], snif_buf[2], snif_buf[3]);
                else
                    $display("  wire %s: %02h %02h  OK", what, snif_buf[0], snif_buf[1]);
            end
        end
    endtask

    // ---------------- clock ----------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ---------------- drivers, one per master ----------------
    task automatic a1_cmd(input logic [15:0] addr, input logic [7:0] wd,
                          input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            while (!a1_ready) @(negedge clk);
            a1_addr = addr; a1_wdata = wd; a1_mode = we; a1_valid = 1'b1;
            @(negedge clk);
            a1_valid = 1'b0;
            @(negedge clk);
            while (!a1_ready) @(negedge clk);
            rd = a1_rdata;
        end
    endtask

    task automatic a2_cmd(input logic [15:0] addr, input logic [7:0] wd,
                          input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            while (!a2_ready) @(negedge clk);
            a2_addr = addr; a2_wdata = wd; a2_mode = we; a2_valid = 1'b1;
            @(negedge clk);
            a2_valid = 1'b0;
            @(negedge clk);
            while (!a2_ready) @(negedge clk);
            rd = a2_rdata;
        end
    endtask

    task automatic b1_cmd(input logic [15:0] addr, input logic [7:0] wd,
                          input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            while (!b1_ready) @(negedge clk);
            b1_addr = addr; b1_wdata = wd; b1_mode = we; b1_valid = 1'b1;
            @(negedge clk);
            b1_valid = 1'b0;
            @(negedge clk);
            while (!b1_ready) @(negedge clk);
            rd = b1_rdata;
        end
    endtask

    task automatic b2_cmd(input logic [15:0] addr, input logic [7:0] wd,
                          input bit we, output logic [7:0] rd);
        begin
            @(negedge clk);
            while (!b2_ready) @(negedge clk);
            b2_addr = addr; b2_wdata = wd; b2_mode = we; b2_valid = 1'b1;
            @(negedge clk);
            b2_valid = 1'b0;
            @(negedge clk);
            while (!b2_ready) @(negedge clk);
            rd = b2_rdata;
        end
    endtask

    // writes are posted: the local master retires as soon as the bridge has the
    // byte. give the frame time to cross and execute before checking the far side.
    task automatic settle;
        begin
            repeat (400) @(posedge clk);
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

    task automatic expect_bit(input string what, input bit got, input bit exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                $display("  FAIL %s: got %0b, expected %0b", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok   %s = %0b", what, got);
        end
    endtask

    // ---------------- stimulus ----------------
    logic [7:0] rd, rd2;
    integer     t0;

    initial begin
        rstn = 1'b0; link_up = 1'b1; snif_en = 1'b0;
        a1_addr='0; a1_wdata='0; a1_valid=1'b0; a1_mode=1'b0;
        a2_addr='0; a2_wdata='0; a2_valid=1'b0; a2_mode=1'b0;
        b1_addr='0; b1_wdata='0; b1_valid=1'b0; b1_mode=1'b0;
        b2_addr='0; b2_wdata='0; b2_valid=1'b0; b2_mode=1'b0;
        repeat (10) @(posedge clk);
        rstn = 1'b1;
        repeat (10) @(posedge clk);

        $display("\n=== 1. local accesses on both boards still work ===");
        a1_cmd(L_S1, 8'h3C, 1'b1, rd);
        a1_cmd(L_S1, 8'h00, 1'b0, rd);
        expect_eq("A m1 local slave1 0x0100", rd, 8'h3C);
        a1_cmd(L_S2, 8'h11, 1'b1, rd);
        a1_cmd(L_S2, 8'h00, 1'b0, rd);
        expect_eq("A m1 local slave2 0x1000", rd, 8'h11);
        a2_cmd(L_S1B, 8'h99, 1'b1, rd);
        a2_cmd(L_S1B, 8'h00, 1'b0, rd);
        expect_eq("A m2 local slave1 0x0200", rd, 8'h99);
        b1_cmd(L_S1, 8'h7E, 1'b1, rd);
        b1_cmd(L_S1, 8'h00, 1'b0, rd);
        expect_eq("B m1 local slave1 0x0100", rd, 8'h7E);

        $display("\n=== 2. wire format: A m1 writes 0x5A to far slave2 0x000 ===");
        // cmd = {wdata, addr14, we, 0}, addr14 = {bdev=01, offset=0x000}
        snif_start();
        a1_cmd(F_S2, 8'h5A, 1'b1, rd);
        settle();
        snif_check("far write req", 4, 8'hA5, 8'h02, 8'h40, 8'h5A);
        b1_cmd(L_S2, 8'h00, 1'b0, rd);
        expect_eq("B m1 sees it locally at 0x1000", rd, 8'h5A);
        a1_cmd(L_S2, 8'h00, 1'b0, rd);
        expect_eq("A's own 0x1000 untouched", rd, 8'h11);

        $display("\n=== 3. A MASTER 1 reaches all three far slaves ===");
        a1_cmd(F_S1, 8'hA1, 1'b1, rd);
        a1_cmd(F_S1, 8'h00, 1'b0, rd);
        expect_eq("A m1 -> far slave1", rd, 8'hA1);
        a1_cmd(F_S2, 8'hA2, 1'b1, rd);
        a1_cmd(F_S2, 8'h00, 1'b0, rd);
        expect_eq("A m1 -> far slave2", rd, 8'hA2);
        a1_cmd(F_S3, 8'hA3, 1'b1, rd);
        a1_cmd(F_S3, 8'h00, 1'b0, rd);
        expect_eq("A m1 -> far slave3", rd, 8'hA3);
        expect_bit("A bridge error clear", a_err, 1'b0);

        $display("\n=== 4. A MASTER 2 reaches all three far slaves ===");
        a2_cmd(F_S1B, 8'hB1, 1'b1, rd);
        a2_cmd(F_S1B, 8'h00, 1'b0, rd);
        expect_eq("A m2 -> far slave1", rd, 8'hB1);
        a2_cmd(F_S2H, 8'hB2, 1'b1, rd);
        a2_cmd(F_S2H, 8'h00, 1'b0, rd);
        expect_eq("A m2 -> far slave2 top of 4K", rd, 8'hB2);
        a2_cmd(F_S3, 8'hB3, 1'b1, rd);
        a2_cmd(F_S3, 8'h00, 1'b0, rd);
        expect_eq("A m2 -> far slave3", rd, 8'hB3);

        $display("\n=== 5. full range: the far board confirms it locally ===");
        b1_cmd(L_S2H, 8'h00, 1'b0, rd);
        expect_eq("B m1 local read of 0x1FFF", rd, 8'hB2);
        b2_cmd(L_S1B, 8'h00, 1'b0, rd);
        expect_eq("B m2 local read of 0x0200", rd, 8'hB1);

        $display("\n=== 6. BOTH far masters write all three of A's slaves ===");
        b1_cmd(F_S1, 8'hC1, 1'b1, rd);      // B m1 -> A slave1
        b1_cmd(F_S2, 8'hC2, 1'b1, rd);      // B m1 -> A slave2
        b2_cmd(F_S3, 8'hC3, 1'b1, rd);      // B m2 -> A slave3
        b2_cmd(F_S2H, 8'hC4, 1'b1, rd);     // B m2 -> A slave2 top of 4K
        settle();
        a1_cmd(L_S1, 8'h00, 1'b0, rd);
        expect_eq("A slave1 written by far m1", rd, 8'hC1);
        a1_cmd(L_S2, 8'h00, 1'b0, rd);
        expect_eq("A slave2 written by far m1", rd, 8'hC2);
        a2_cmd(L_S3, 8'h00, 1'b0, rd);
        expect_eq("A slave3 written by far m2", rd, 8'hC3);
        a2_cmd(L_S2H, 8'h00, 1'b0, rd);
        expect_eq("A slave2 0x1FFF written by far m2", rd, 8'hC4);

        $display("\n=== 7. far read of the slow split slave ===");
        b1_cmd(L_S3, 8'hD9, 1'b1, rd);      // B writes its own slave3
        b1_cmd(L_S3, 8'h00, 1'b0, rd);
        expect_eq("B local slave3 0x2800", rd, 8'hD9);
        a1_cmd(F_S3, 8'h00, 1'b0, rd);      // A reads it across the link
        expect_eq("A m1 far read of B slave3", rd, 8'hD9);

        $display("\n=== 8. local traffic runs while a far read is outstanding ===");
        // the bridge holds ssplit for the whole round trip, so m2 must be able
        // to use the bus meanwhile. both must give the right answer.
        fork
            a1_cmd(F_S1, 8'h00, 1'b0, rd);
            begin
                repeat (6) @(posedge clk);
                a2_cmd(L_S1B, 8'h00, 1'b0, rd2);
            end
        join
        expect_eq("A m1 far read during overlap", rd, 8'hA1);
        expect_eq("A m2 local read during overlap", rd2, 8'h99);

        $display("\n=== 9. both boards read each other at the same moment ===");
        fork
            a1_cmd(F_S1, 8'h00, 1'b0, rd);
            b1_cmd(F_S1, 8'h00, 1'b0, rd2);
        join
        expect_eq("A m1 read of B slave1", rd,  8'hA1);
        expect_eq("B m1 read of A slave1", rd2, 8'hC1);

        $display("\n=== 10. cut the link, a far read must error not hang ===");
        link_up = 1'b0;
        t0 = $time;
        a1_cmd(F_S2, 8'h00, 1'b0, rd);
        expect_bit("A bridge error with cable cut", a_err, 1'b1);
        expect_eq("A returns 0xFF on timeout", rd, 8'hFF);
        checks = checks + 1;
        if (($time - t0) > (RESP_TIMEOUT + 800) * CLK_PERIOD) begin
            $display("  FAIL timeout took %0t, too long", $time - t0);
            errors = errors + 1;
        end else
            $display("  ok   timed out and completed in %0t", $time - t0);

        $display("\n=== 11. local access still works with the link down ===");
        a1_cmd(L_S1, 8'h6B, 1'b1, rd);
        a1_cmd(L_S1, 8'h00, 1'b0, rd);
        expect_eq("A m1 local slave1 with link down", rd, 8'h6B);
        a2_cmd(L_S1B, 8'h00, 1'b0, rd);
        expect_eq("A m2 local with link down", rd, 8'h99);

        $display("\n=== 12. link restored, far access works again ===");
        link_up = 1'b1;
        repeat (100) @(posedge clk);
        a1_cmd(F_S2, 8'h00, 1'b0, rd);
        expect_eq("A m1 far read after reconnect", rd, 8'hA2);
        expect_bit("A bridge error cleared", a_err, 1'b0);

        $display("\n=====================================================");
        if (errors == 0)
            $display("PASS - all %0d checks passed", checks);
        else
            $display("FAIL - %0d of %0d checks failed", errors, checks);
        $display("=====================================================\n");
        $finish;
    end

    // hard stop so a hang shows up as a failure rather than running forever
    initial begin
        #8_000_000;
        $display("FAIL - testbench timed out, something hung");
        $finish;
    end

endmodule
