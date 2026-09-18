`timescale 1ns/1ps

// grabs device id off the serial line, picks a target, acks the master.
//
// same machine as addr_decoder, widened from 3 slaves to 3 slaves + a bridge:
//
//   device id 0,1,2   -> S1, S2, S3          (local, unchanged)
//   device id 8,9,10  -> BRIDGE              (far system, far slave = id-8)
//   anything else     -> no ack, master times out
//
// the bridge needs to know WHICH of its three ids was hit, because that is
// the far side's device id. the device id is consumed here and never reaches
// a slave port, so it is handed to the bridge separately on bdev.
module addr_decoder4 #(
    parameter ADDR_WIDTH        = 16,
    parameter DEVICE_ADDR_WIDTH = 4
)(
    input  logic clk,
    input  logic rstn,

    input  logic mwdata,
    input  logic mvalid,

    input  logic ssplit3,        // slave 3 split, split capable
    input  logic ssplitb,        // bridge split, split capable
    input  logic split_grant,

    input  logic sready1,
    input  logic sready2,
    input  logic sready3,
    input  logic sreadyb,

    output logic mvalid1,
    output logic mvalid2,
    output logic mvalid3,
    output logic mvalidb,

    output logic [1:0] ssel,     // 00 s1, 01 s2, 10 s3, 11 bridge
    output logic [1:0] bdev,     // far device id when the bridge is selected

    output logic ack,

    // static snapshot for the JTAG diag word
    output logic [1:0] dbg_state
);

    logic [DEVICE_ADDR_WIDTH-1:0] slave_addr;
    logic                         slave_en;
    logic                         mvalid_out;
    logic                         slave_addr_valid;
    logic [3:0]                   counter;
    logic [DEVICE_ADDR_WIDTH-1:0] split_slave_addr;
    logic                         cur_split, cur_split_q, cur_split_rise;

    dec4 mvalid_decoder (
        .sel (ssel),
        .en  (mvalid_out),
        .out1(mvalid1),
        .out2(mvalid2),
        .out3(mvalid3),
        .outb(mvalidb)
    );

    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        ADDR    = 2'b01,
        CONNECT = 2'b10,
        WAIT    = 2'b11
    } state_t;

    state_t state, next_state;

    // ---------------------------------------------------------------
    // target selection off the freshly shifted device id
    // ids 8..10 are the bridge, ids 0..2 are the local slaves
    // ---------------------------------------------------------------
    logic is_bridge, is_local, tgt_ready;

    assign is_bridge = slave_addr[3] & ~slave_addr[2] & (slave_addr[1:0] != 2'b11);
    assign is_local  = (slave_addr < 3);

    always_comb begin
        if      (is_bridge)                            cur_split = ssplitb;
        else if (is_local && (slave_addr[1:0] == 2'b10)) cur_split = ssplit3;
        else                                           cur_split = 1'b0;
    end

    always_comb begin
        if      (is_bridge) tgt_ready = sreadyb;
        else if (is_local ) tgt_ready = (slave_addr[1:0] == 2'b00) ? sready1 :
                                        (slave_addr[1:0] == 2'b01) ? sready2 : sready3;
        else                tgt_ready = 1'b0;
    end

    always_comb begin
        unique case (state)
            IDLE    : next_state = mvalid ? ADDR : (split_grant ? WAIT : IDLE);
            ADDR    : next_state = (counter == DEVICE_ADDR_WIDTH-1) ? CONNECT : ADDR;
            CONNECT : next_state = slave_addr_valid ? (mvalid ? WAIT : CONNECT) : IDLE;
            WAIT    : next_state = (tgt_ready | cur_split) ? IDLE : WAIT;
            default : next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) state <= IDLE;
        else       state <= next_state;
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) cur_split_q <= 1'b0;
        else       cur_split_q <= cur_split;
    end
    assign cur_split_rise = cur_split & ~cur_split_q;

    assign mvalid_out       = mvalid & slave_en;
    assign slave_addr_valid = (is_bridge | is_local) & tgt_ready;  // known target + ready
    assign ack              = (state == CONNECT) & slave_addr_valid;  // bad address = no ack
    assign dbg_state        = state;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            slave_addr       <= '0;
            slave_en         <= 1'b0;
            counter          <= '0;
            ssel             <= '0;
            bdev             <= '0;
        end else begin
            unique case (state)
                IDLE: begin
                    slave_en <= 1'b0;
                    if (mvalid) begin       // bit 0 of device id
                        slave_addr[0] <= mwdata;
                        counter       <= 1;
                    end else if (split_grant) begin
                        slave_addr <= split_slave_addr;  // reconnect split target
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
                    ssel     <= is_bridge ? 2'b11 : slave_addr[1:0];
                    bdev     <= slave_addr[1:0];
                end

                WAIT: begin
                    slave_en <= 1'b1;
                    ssel     <= is_bridge ? 2'b11 : slave_addr[1:0];
                    bdev     <= slave_addr[1:0];
                end

                default: ;
            endcase
        end
    end

    // remember who split, sampled the instant it splits
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn)           split_slave_addr <= '0;
        else if (cur_split_rise) split_slave_addr <= slave_addr;
    end

endmodule

// tiny one-hot decoder, 3 slaves + bridge
module dec4 (
    input  logic [1:0] sel,
    input  logic       en,
    output logic       out1,
    output logic       out2,
    output logic       out3,
    output logic       outb
);
    assign out1 = en & (sel == 2'b00);
    assign out2 = en & (sel == 2'b01);
    assign out3 = en & (sel == 2'b10);
    assign outb = en & (sel == 2'b11);
endmodule
