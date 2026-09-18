`timescale 1ns/1ps

// priority arbiter, M1 > M2 > M3. M3 is the bridge's master face, so remote
// traffic never starves the two local masters. tracks the split owner too.
//
// same machine as arbiter, widened from 2 masters to 3. one extra output:
// split_busy, so the interconnect can keep a SECOND split-capable target from
// being addressed while a split is already outstanding (the bookkeeping below
// only has room for one owner).
module arbiter3 (
    input  logic clk,
    input  logic rstn,

    input  logic breq1,
    input  logic breq2,
    input  logic breq3,

    input  logic sready1,
    input  logic sready2,
    input  logic sreadysp,   // all split capable targets ready

    input  logic ssplit,

    output logic bgrant1,
    output logic bgrant2,
    output logic bgrant3,

    output logic [1:0] msel,   // 00 m1, 01 m2, 10 m3

    output logic msplit1,
    output logic msplit2,
    output logic msplit3,
    output logic split_grant,
    output logic split_busy,

    // static snapshot for the JTAG diag word, see Sytembus_top
    output logic [1:0] dbg_owner,
    output logic [2:0] dbg_state
);

    logic sready, sready_nsplit;
    assign sready        = sready1 & sready2 & sreadysp;
    assign sready_nsplit = sready1 & sready2;

    typedef enum logic [1:0] {NONE = 2'b00, SM1 = 2'b01, SM2 = 2'b10, SM3 = 2'b11} owner_t;
    owner_t split_owner;

    typedef enum logic [2:0] {IDLE = 3'b000, M1 = 3'b001, M2 = 3'b010, M3 = 3'b011} state_t;
    state_t state, next_state;

    assign split_busy = (split_owner != NONE);
    assign dbg_owner  = split_owner;
    assign dbg_state  = state;

    always_comb begin
        unique case (state)
            IDLE: begin
                if (!ssplit) begin
                    // split done or never happened. a pending owner is
                    // reconnected first, it already has a transaction in flight
                    if      (split_owner == SM1)  next_state = M1;
                    else if (split_owner == SM2)  next_state = M2;
                    else if (split_owner == SM3)  next_state = M3;
                    else if (breq1 & sready)      next_state = M1;
                    else if (breq2 & sready)      next_state = M2;
                    else if (breq3 & sready)      next_state = M3;
                    else                          next_state = IDLE;
                end else begin
                    // split pending, let anyone but the owner through
                    if      ((split_owner != SM1) && breq1 && sready_nsplit) next_state = M1;
                    else if ((split_owner != SM2) && breq2 && sready_nsplit) next_state = M2;
                    else if ((split_owner != SM3) && breq3 && sready_nsplit) next_state = M3;
                    else                                                     next_state = IDLE;
                end
            end
            M1: next_state = (!breq1 | (split_owner == NONE && ssplit)) ? IDLE : M1;
            M2: next_state = (!breq2 | (split_owner == NONE && ssplit)) ? IDLE : M2;
            M3: next_state = (!breq3 | (split_owner == NONE && ssplit)) ? IDLE : M3;
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) state <= IDLE;
        else       state <= next_state;
    end

    assign bgrant1 = (state == M1);
    assign bgrant2 = (state == M2);
    assign bgrant3 = (state == M3);
    assign msel    = (state == M2) ? 2'b01 : (state == M3) ? 2'b10 : 2'b00;

    // split bookkeeping
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            msplit1     <= 1'b0;
            msplit2     <= 1'b0;
            msplit3     <= 1'b0;
            split_owner <= NONE;
            split_grant <= 1'b0;
        end else begin
            unique case (state)
                M1: begin
                    if (split_owner == NONE && ssplit) begin
                        msplit1     <= 1'b1;
                        split_owner <= SM1;
                        split_grant <= 1'b0;
                    end else if (split_owner == SM1 && !ssplit) begin
                        msplit1     <= 1'b0;
                        split_owner <= NONE;
                        split_grant <= 1'b1;
                    end else
                        split_grant <= 1'b0;
                end
                M2: begin
                    if (split_owner == NONE && ssplit) begin
                        msplit2     <= 1'b1;
                        split_owner <= SM2;
                        split_grant <= 1'b0;
                    end else if (split_owner == SM2 && !ssplit) begin
                        msplit2     <= 1'b0;
                        split_owner <= NONE;
                        split_grant <= 1'b1;
                    end else
                        split_grant <= 1'b0;
                end
                M3: begin
                    if (split_owner == NONE && ssplit) begin
                        msplit3     <= 1'b1;
                        split_owner <= SM3;
                        split_grant <= 1'b0;
                    end else if (split_owner == SM3 && !ssplit) begin
                        msplit3     <= 1'b0;
                        split_owner <= NONE;
                        split_grant <= 1'b1;
                    end else
                        split_grant <= 1'b0;
                end
                default: split_grant <= 1'b0;
            endcase
        end
    end

endmodule
