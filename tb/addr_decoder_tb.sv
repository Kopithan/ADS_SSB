`timescale 1ns/1ps

// decoder unit test: shift in device ids, check ssel/ack/mvalid routing
module addr_decoder_tb;

    parameter DEVICE_ADDR_WIDTH = 4;

    logic clk, rstn;
    logic mwdata, mvalid;
    logic ssplit, split_grant;
    logic sready1, sready2, sready3;
    logic mvalid1, mvalid2, mvalid3;
    logic [1:0] ssel;
    logic ack;

    integer errors = 0;

    addr_decoder #(.ADDR_WIDTH(16), .DEVICE_ADDR_WIDTH(DEVICE_ADDR_WIDTH)) dut (.*);

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

    // shift device id LSB first, like the master does
    task send_id(input logic [DEVICE_ADDR_WIDTH-1:0] id);
        integer k;
        begin
            for (k = 0; k < DEVICE_ADDR_WIDTH; k = k + 1) begin
                @(posedge clk);
                mwdata = id[k];
                mvalid = 1;
            end
            @(posedge clk);
            mvalid = 0;
        end
    endtask

    task finish_txn;
        begin
            // drop ready like a busy slave, then release
            repeat (2) @(posedge clk);
            case (ssel)
                2'b00: sready1 = 0;
                2'b01: sready2 = 0;
                2'b10: sready3 = 0;
            endcase
            repeat (3) @(posedge clk);
            {sready3, sready2, sready1} = 3'b111;
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("addr_decoder_tb.vcd");
        $dumpvars(0, addr_decoder_tb);

        rstn = 0;
        mwdata = 0; mvalid = 0;
        ssplit = 0; split_grant = 0;
        sready1 = 1; sready2 = 1; sready3 = 1;
        repeat (3) @(posedge clk);

        // reset test - no ack, no slave selected, no mvalid routed anywhere
        #1;
        check(!ack,                             "reset: no ack");
        check(ssel == 2'b00,                    "reset: ssel cleared");
        check(!mvalid1 && !mvalid2 && !mvalid3, "reset: no slave selected");

        rstn = 1;
        repeat (2) @(posedge clk);

        // async reset: select a slave, then drop rstn with no clock edge
        send_id(4'b0000);
        @(posedge clk); #1;
        check(ack, "reset: ack asserted before the async reset test");
        rstn = 0;
        #1;   // no clock edge between here and the check
        check(!ack && !mvalid1 && !mvalid2 && !mvalid3,
              "reset: async reset clears the selection with no clock edge");
        mvalid = 0;
        rstn = 1;
        repeat (3) @(posedge clk);

        // pick slave 1 (id 0)
        send_id(4'b0000);
        @(posedge clk); #1;
        check(ack, "ack for slave1");
        check(ssel == 2'b00, "ssel points to slave1");
        // mvalid should route to slave1 only
        mvalid = 1;
        @(posedge clk); #1;
        check(mvalid1 && !mvalid2 && !mvalid3, "mvalid routed to slave1");
        mvalid = 0;
        finish_txn();

        // pick slave 3 (id 2)
        send_id(4'b0010);
        @(posedge clk); #1;
        check(ack, "ack for slave3");
        check(ssel == 2'b10, "ssel points to slave3");
        mvalid = 1;
        @(posedge clk); #1;
        check(mvalid3 && !mvalid1 && !mvalid2, "mvalid routed to slave3");
        mvalid = 0;
        finish_txn();

        // invalid id -> no ack
        send_id(4'b0111);
        repeat (2) @(posedge clk); #1;
        check(!ack, "no ack for bad id");
        repeat (3) @(posedge clk);

        // busy slave -> no ack either
        sready2 = 0;
        send_id(4'b0001);
        @(posedge clk); #1;
        check(!ack, "no ack when slave2 busy");
        sready2 = 1;
        repeat (3) @(posedge clk);

        // split reconnect: decoder should jump back to the split slave
        send_id(4'b0010);
        @(posedge clk);
        mvalid = 1;                 // hold connection
        @(posedge clk);             // decoder moves CONNECT -> WAIT here
        sready3 = 0;                // slave3 now busy with the transaction
        repeat (2) @(posedge clk);
        mvalid = 0;
        ssplit = 1;                 // slave3 splits, decoder saves addr + disconnects
        @(posedge clk);
        ssplit = 0;
        repeat (2) @(posedge clk); #1;
        check(dut.state == 2'b00, "decoder back to idle during split");
        split_grant = 1;            // arbiter resumes split
        @(posedge clk);
        split_grant = 0;
        repeat (2) @(posedge clk); #1;
        check(ssel == 2'b10, "split reconnects to slave3");
        sready3 = 1;                // slave done, decoder releases
        repeat (3) @(posedge clk);

        if (errors == 0) $display("\n=== addr_decoder_tb PASSED ===");
        else             $display("\n=== addr_decoder_tb: %0d ERRORS ===", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
