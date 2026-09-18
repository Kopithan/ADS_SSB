`timescale 1ns/1ps
//=============================================================================
// frames_tb
//
// Not a pass/fail bench. It prints the EXACT bytes this board puts on rm_tx
// for each kind of far access, and the exact bytes it expects back on rm_rx.
//
// Hand this table to the team on the other board. If their parser does not
// accept these four bytes, our writes never land on their memory and our
// reads never get an answer - which is exactly what a board that can read
// and write US, while we cannot touch IT, looks like.
//
// A write is POSTED: we send the request and expect nothing back. So if a
// far write does not land on their memory, their receive/execute path is at
// fault, because no response logic of any kind is involved in a write.
//=============================================================================

module frames_tb;

    parameter CLK_PERIOD = 10;
    parameter HOLD       = 3000;
    parameter DRAIN      = 800;

    logic clk, rstn;
    logic [15:0] d1_addr, d2_addr;
    logic [7:0]  d1_wdata, d2_wdata, d1_rdata, d2_rdata;
    logic        d1_valid, d2_valid, d1_ready, d2_ready, d1_mode, d2_mode;
    logic        rm_tx, br_error;

    Sytembus #(.CLKS_PER_BIT(4), .RESP_TIMEOUT(3000)) dut (
        .clk(clk), .rstn(rstn),
        .d1_addr(d1_addr), .d1_wdata(d1_wdata), .d1_rdata(d1_rdata),
        .d1_valid(d1_valid), .d1_ready(d1_ready), .d1_mode(d1_mode),
        .d2_addr(d2_addr), .d2_wdata(d2_wdata), .d2_rdata(d2_rdata),
        .d2_valid(d2_valid), .d2_ready(d2_ready), .d2_mode(d2_mode),
        .rm_rx(1'b1), .rm_tx(rm_tx), .br_error(br_error)   // no far board
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ------------------------------------------------------------------
    // capture every byte handed to the uart transmitter
    // ------------------------------------------------------------------
    logic [7:0] cap [0:7];
    integer     ncap = 0;
    bit         capturing = 0;

    always @(posedge clk) begin
        if (capturing && dut.bridge.u_en && ncap < 8) begin
            cap[ncap] = dut.bridge.u_din;
            ncap      = ncap + 1;
        end
    end

    task automatic show(input string label);
        begin
            $write("  %-34s ", label);
            for (int i = 0; i < ncap; i++) $write("%02X ", cap[i]);
            if (ncap == 0) $write("(nothing sent)");
            $write("\n");
        end
    endtask

    task automatic far(input logic [15:0] a, input logic [7:0] d, input bit we,
                       input string label);
        logic [7:0] rd;
        begin
            ncap = 0; capturing = 1;
            @(negedge clk);
            d1_addr = a; d1_wdata = d; d1_mode = we; d1_valid = 1'b1;
            repeat (HOLD) @(posedge clk);
            @(negedge clk);
            d1_valid = 1'b0;
            repeat (DRAIN) @(posedge clk);
            capturing = 0;
            show(label);
        end
    endtask

    initial begin
        rstn = 0;
        d1_addr='0; d1_wdata='0; d1_valid=0; d1_mode=0;
        d2_addr='0; d2_wdata='0; d2_valid=0; d2_mode=0;
        repeat (10) @(posedge clk); rstn = 1; repeat (10) @(posedge clk);

        $display("");
        $display("=====================================================================");
        $display(" BYTES THIS BOARD SENDS ON rm_tx   (8N1, 115200 baud, LSB first)");
        $display("=====================================================================");
        $display("  REQUEST frame  : A5  b0  b1  b2      cmd = {wdata[7:0], addr[13:0], we, 1'b0}");
        $display("                   b0 = cmd[7:0], b1 = cmd[15:8], b2 = cmd[23:16]  (little endian)");
        $display("  addr[13:0]     = {device[1:0], offset[11:0]}   device 0=S1 1=S2 2=S3");
        $display("  RESPONSE frame : 5A  data            reads only, writes are POSTED");
        $display("");
        $display("  bus address -> what goes out on the wire");
        $display("  -------------------------------------------------------------------");

        far(16'h9005, 8'hD7, 1'b1, "w 9005 D7  <- their worked example");
        far(16'h8008, 8'h65, 1'b1, "w 8008 65  (their S1 off 008)");
        far(16'h8008, 8'h00, 1'b0, "r 8008     (their S1 off 008)");
        far(16'h8001, 8'h10, 1'b1, "w 8001 10  (their S1 off 001)");
        far(16'h8001, 8'h00, 1'b0, "r 8001     (their S1 off 001)");
        far(16'h9001, 8'h12, 1'b1, "w 9001 12  (their S2 off 001)");
        far(16'h9001, 8'h00, 1'b0, "r 9001     (their S2 off 001)");
        far(16'hA005, 8'h57, 1'b1, "w A005 57  (their S3 off 005)");
        far(16'hA005, 8'h00, 1'b0, "r A005     (their S3 off 005)");
        far(16'h8000, 8'hA1, 1'b1, "w 8000 A1  (their S1 off 000)");
        far(16'h9FFF, 8'hB2, 1'b1, "w 9FFF B2  (their S2 off FFF)");

        $display("");
        $display("  For each READ above, the far board must reply with exactly two");
        $display("  bytes: 5A then the data byte. For each WRITE it must reply with");
        $display("  NOTHING and just perform the write.");
        $display("=====================================================================");
        $display("");
        $finish;
    end

    initial begin #20_000_000; $display("frames_tb timed out"); $finish; end
endmodule
