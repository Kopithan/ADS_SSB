`timescale 1ns/1ps

// grabs device id off the serial line, picks a slave, acks the master
module addr_decoder #(
    parameter ADDR_WIDTH        = 16,
    parameter DEVICE_ADDR_WIDTH = 4
)(
    input  logic clk,
    input  logic rstn,

    input  logic mwdata,
    input  logic mvalid,

    input  logic ssplit,
    input  logic split_grant,

    input  logic sready1,
    input  logic sready2,
    input  logic sready3,

    output logic mvalid1,
    output logic mvalid2,
    output logic mvalid3,

    output logic [1:0] ssel,

    output logic ack
);

    logic [DEVICE_ADDR_WIDTH-1:0] slave_addr;
    logic                         slave_en;
    logic                         mvalid_out;
    logic                         slave_addr_valid;
    logic [2:0]                   sready;
    logic [3:0]                   counter;
    logic [DEVICE_ADDR_WIDTH-1:0] split_slave_addr;

    dec3 mvalid_decoder (
        .sel (ssel),
        .en  (mvalid_out),
        .out1(mvalid1),
        .out2(mvalid2),
        .out3(mvalid3)
    );

    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        ADDR    = 2'b01,
        CONNECT = 2'b10,
        WAIT    = 2'b11
    } state_t;

    state_t state, next_state;

    always_comb begin
        unique case (state)
            IDLE    : next_state = mvalid ? ADDR : (split_grant ? WAIT : IDLE);
            ADDR    : next_state = (counter == DEVICE_ADDR_WIDTH-1) ? CONNECT : ADDR;
            CONNECT : next_state = slave_addr_valid ? (mvalid ? WAIT : CONNECT) : IDLE;
            WAIT    : next_state = (sready[slave_addr] | ssplit) ? IDLE : WAIT;
            default : next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) state <= IDLE;
        else       state <= next_state;
    end

    assign mvalid_out       = mvalid & slave_en;
    assign slave_addr_valid = (slave_addr < 3) & sready[slave_addr];  // known slave + ready
    assign ack              = (state == CONNECT) & slave_addr_valid;  // bad address = no ack
    assign sready           = {sready3, sready2, sready1};

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            slave_addr       <= '0;
            slave_en         <= 1'b0;
            counter          <= '0;
            ssel             <= '0;
            split_slave_addr <= '0;
        end else begin
            unique case (state)
                IDLE: begin
                    slave_en <= 1'b0;
                    if (mvalid) begin       // bit 0 of device id
                        slave_addr[0] <= mwdata;
                        counter       <= 1;
                    end else if (split_grant) begin
                        slave_addr <= split_slave_addr;  // reconnect split slave
                        counter    <= '0;
                    end else
                        counter <= '0;
                end

                ADDR: begin  // rest of device id, LSB first
                    slave_addr[counter] <= mwdata;
                    counter <= (counter == DEVICE_ADDR_WIDTH-1) ? '0 : counter + 1;
                end

                CONNECT: begin
                    slave_en <= 1'b1;
                    ssel     <= slave_addr[1:0];
                end

                WAIT: begin
                    slave_en <= 1'b1;
                    ssel     <= slave_addr[1:0];
                    if (ssplit) split_slave_addr <= slave_addr;  // remember who split
                end

                default: ;
            endcase
        end
    end

endmodule

// tiny one-hot decoder
module dec3 (
    input  logic [1:0] sel,
    input  logic       en,
    output logic       out1,
    output logic       out2,
    output logic       out3
);
    assign out1 = en & (sel == 2'b00);
    assign out2 = en & (sel == 2'b01);
    assign out3 = en & (sel == 2'b10);
endmodule
