`timescale 1ns/1ps

// priority arbiter, M1 wins. tracks split owner too.
module arbiter (
    input  logic clk,
    input  logic rstn,

    input  logic breq1,
    input  logic breq2,

    input  logic sready1,
    input  logic sready2,
    input  logic sreadysp,   // split capable slave

    input  logic ssplit,

    output logic bgrant1,
    output logic bgrant2,

    output logic msel,       // 0 m1, 1 m2

    output logic msplit1,
    output logic msplit2,
    output logic split_grant
);

    logic sready, sready_nsplit;
    assign sready        = sready1 & sready2 & sreadysp;
    assign sready_nsplit = sready1 & sready2;

    typedef enum logic [1:0] {NONE = 2'b00, SM1 = 2'b01, SM2 = 2'b10} owner_t;
    owner_t split_owner;

    typedef enum logic [2:0] {IDLE = 3'b000, M1 = 3'b001, M2 = 3'b010} state_t;
    state_t state, next_state;

    always_comb begin
        unique case (state)
            IDLE: begin
                if (!ssplit) begin
                    // split done or never happened
                    if      (split_owner == SM1)  next_state = M1;
                    else if (breq1 & sready)      next_state = M1;
                    else if (split_owner == SM2)  next_state = M2;
                    else if (breq2 & sready)      next_state = M2;
                    else                          next_state = IDLE;
                end else begin
                    // split pending, let the other master through
                    if      ((split_owner == SM1) && breq2 && sready_nsplit) next_state = M2;
                    else if ((split_owner == SM2) && breq1 && sready_nsplit) next_state = M1;
                    else                                                     next_state = IDLE;
                end
            end
            M1: next_state = (!breq1 | (split_owner == NONE && ssplit)) ? IDLE : M1;
            M2: next_state = (!breq2 | (split_owner == NONE && ssplit)) ? IDLE : M2;
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) state <= IDLE;
        else       state <= next_state;
    end

    assign bgrant1 = (state == M1);
    assign bgrant2 = (state == M2);
    assign msel    = (state == M2);

    // split bookkeeping
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            msplit1     <= 1'b0;
            msplit2     <= 1'b0;
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
                default: ;
            endcase
        end
    end

endmodule
