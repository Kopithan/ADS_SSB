`timescale 1ns/1ps

// uart tx: start bit, N data bits LSB first, stop bit
module uart_tx #(
    parameter CLOCKS_PER_PULSE = 5208,
    parameter DATA_WIDTH       = 8
)(
    input  logic                  clk,
    input  logic                  rstn,
    input  logic [DATA_WIDTH-1:0] data_in,
    input  logic                  data_en,
    output logic                  tx,
    output logic                  tx_busy
);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;

    logic [DATA_WIDTH-1:0] shift;
    logic [$clog2(DATA_WIDTH)-1:0] bit_cnt;
    logic [$clog2(CLOCKS_PER_PULSE)-1:0] clk_cnt;

    assign tx_busy = (state != IDLE);

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state   <= IDLE;
            tx      <= 1'b1;
            shift   <= '0;
            bit_cnt <= '0;
            clk_cnt <= '0;
        end else begin
            unique case (state)
                IDLE: begin
                    tx      <= 1'b1;
                    clk_cnt <= '0;
                    bit_cnt <= '0;
                    if (data_en) begin
                        shift <= data_in;
                        state <= START;
                    end
                end

                START: begin
                    tx <= 1'b0;
                    if (clk_cnt == CLOCKS_PER_PULSE-1) begin
                        clk_cnt <= '0;
                        state   <= DATA;
                    end else clk_cnt <= clk_cnt + 1;
                end

                DATA: begin
                    tx <= shift[bit_cnt];
                    if (clk_cnt == CLOCKS_PER_PULSE-1) begin
                        clk_cnt <= '0;
                        if (bit_cnt == DATA_WIDTH-1) begin
                            bit_cnt <= '0;
                            state   <= STOP;
                        end else bit_cnt <= bit_cnt + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end

                STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLOCKS_PER_PULSE-1) begin
                        clk_cnt <= '0;
                        state   <= IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end

endmodule

// uart rx: samples mid bit
module uart_rx #(
    parameter CLOCKS_PER_PULSE = 5208,
    parameter DATA_WIDTH       = 8
)(
    input  logic                  clk,
    input  logic                  rstn,
    input  logic                  rx,
    output logic [DATA_WIDTH-1:0] data_out,
    output logic                  ready
);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;

    logic [DATA_WIDTH-1:0] shift;
    logic [$clog2(DATA_WIDTH)-1:0] bit_cnt;
    logic [$clog2(CLOCKS_PER_PULSE)-1:0] clk_cnt;

    // sync rx, it comes from outside
    logic rx_q, rx_qq;
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) {rx_qq, rx_q} <= 2'b11;
        else       {rx_qq, rx_q} <= {rx_q, rx};
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state    <= IDLE;
            shift    <= '0;
            bit_cnt  <= '0;
            clk_cnt  <= '0;
            data_out <= '0;
            ready    <= 1'b0;
        end else begin
            unique case (state)
                IDLE: begin
                    ready   <= 1'b0;
                    clk_cnt <= '0;
                    bit_cnt <= '0;
                    if (!rx_qq) state <= START;   // start bit edge
                end

                START: begin
                    // wait half a bit to hit the middle
                    if (clk_cnt == (CLOCKS_PER_PULSE/2)-1) begin
                        clk_cnt <= '0;
                        state   <= rx_qq ? IDLE : DATA;  // glitch check
                    end else clk_cnt <= clk_cnt + 1;
                end

                DATA: begin
                    if (clk_cnt == CLOCKS_PER_PULSE-1) begin
                        clk_cnt        <= '0;
                        shift[bit_cnt] <= rx_qq;
                        if (bit_cnt == DATA_WIDTH-1) begin
                            bit_cnt <= '0;
                            state   <= STOP;
                        end else bit_cnt <= bit_cnt + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end

                STOP: begin
                    if (clk_cnt == CLOCKS_PER_PULSE-1) begin
                        clk_cnt  <= '0;
                        data_out <= shift;
                        ready    <= 1'b1;
                        state    <= IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end

endmodule

// tx + rx bundled, widths can differ per direction
module uart #(
    parameter CLOCKS_PER_PULSE = 5208,
    parameter TX_DATA_WIDTH    = 8,
    parameter RX_DATA_WIDTH    = 8
)(
    input  logic                     clk,
    input  logic                     rstn,
    input  logic [TX_DATA_WIDTH-1:0] data_input,
    input  logic                     data_en,
    output logic                     tx,
    output logic                     tx_busy,
    input  logic                     rx,
    output logic [RX_DATA_WIDTH-1:0] data_output,
    output logic                     ready
);

    uart_tx #(.CLOCKS_PER_PULSE(CLOCKS_PER_PULSE), .DATA_WIDTH(TX_DATA_WIDTH)) transmitter (
        .clk(clk), .rstn(rstn), .data_in(data_input), .data_en(data_en),
        .tx(tx), .tx_busy(tx_busy)
    );

    uart_rx #(.CLOCKS_PER_PULSE(CLOCKS_PER_PULSE), .DATA_WIDTH(RX_DATA_WIDTH)) receiver (
        .clk(clk), .rstn(rstn), .rx(rx),
        .data_out(data_output), .ready(ready)
    );

endmodule
