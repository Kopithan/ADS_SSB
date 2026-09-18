`timescale 1ns/1ps

// uart loopback: tx wired to rx, send a few words, expect them back
module uart_tb;

    parameter CLOCKS_PER_PULSE = 8;   // small for sim speed
    parameter DATA_WIDTH = 21;        // bridge frame size

    logic clk, rstn;
    logic [DATA_WIDTH-1:0] data_input;
    logic data_en, tx, tx_busy, ready;
    logic [DATA_WIDTH-1:0] data_output;

    integer errors = 0;
    integer k;
    logic [DATA_WIDTH-1:0] sent;

    uart #(
        .CLOCKS_PER_PULSE(CLOCKS_PER_PULSE),
        .TX_DATA_WIDTH(DATA_WIDTH),
        .RX_DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk), .rstn(rstn),
        .data_input(data_input), .data_en(data_en),
        .tx(tx), .tx_busy(tx_busy),
        .rx(tx),                       // loopback
        .data_output(data_output), .ready(ready)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("uart_tb.vcd");
        $dumpvars(0, uart_tb);

        rstn = 0; data_en = 0; data_input = '0;
        repeat (3) @(posedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);

        for (k = 0; k < 5; k = k + 1) begin
            sent = $urandom;
            data_input = sent;
            data_en = 1;
            @(posedge clk);
            data_en = 0;

            @(posedge ready);
            @(posedge clk);
            if (data_output !== sent) begin
                $display("ERROR: sent 0x%0h got 0x%0h", sent, data_output);
                errors = errors + 1;
            end else
                $display("PASS: 0x%0h looped back", sent);

            wait (!tx_busy);
            repeat (5) @(posedge clk);
        end

        if (errors == 0) $display("\n=== uart_tb PASSED ===");
        else             $display("\n=== uart_tb: %0d ERRORS ===", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
