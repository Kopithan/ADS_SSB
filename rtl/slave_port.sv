`timescale 1ns/1ps

module slave_port #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 8,
    parameter SPLIT_EN   = 0,
    // Escape hatch for SPLIT/WAIT. If the split_grant reconnect is ever lost,
    // the port would sit in WAIT forever with sready low - and the arbiter
    // will not grant ANY master until EVERY slave is ready, so one lost
    // handshake takes the whole bus down until the reset button. Must exceed
    // the longest legitimate wait: the bridge's slave face parks here for up
    // to RESP_TIMEOUT (500k) cycles.
    parameter STUCK_TIMEOUT = 2000000
)(
    input  logic clk,
    input  logic rstn,

    // memory side
    input  logic [DATA_WIDTH-1:0] smemrdata,
    input  logic                  rvalid,
    output logic                  smemwen,
    output logic                  smemren,
    output logic [ADDR_WIDTH-1:0] smemaddr,
    output logic [DATA_WIDTH-1:0] smemwdata,

    // serial bus side
    input  logic swdata,
    output logic srdata,
    input  logic smode,       // 0 read, 1 write
    input  logic mvalid,
    input  logic split_grant,
    output logic svalid,
    output logic sready,
    output logic ssplit
);

    logic [DATA_WIDTH-1:0] wdata;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] rdata;
    logic                  mode;

    logic [7:0] counter;

    // fake latency before split ends
    localparam LATENCY = 4;
    logic [LATENCY-1:0] rcounter;

    // watchdog for SPLIT and WAIT
    localparam STUCK_W = $clog2(STUCK_TIMEOUT+1);
    logic [STUCK_W-1:0] stuck;
    logic               stuck_hit;
    assign stuck_hit = (stuck == STUCK_TIMEOUT[STUCK_W-1:0]);

    typedef enum logic [2:0] {
        IDLE   = 3'b000,
        ADDR   = 3'b001,
        RDATA  = 3'b010,
        WDATA  = 3'b011,
        SREADY = 3'b101,
        SPLIT  = 3'b100,
        WAIT   = 3'b110,
        RVALID = 3'b111
    } state_t;

    state_t state, next_state, prev_state;

    always_comb begin
        unique case (state)
            IDLE   : next_state = mvalid ? ADDR : IDLE;
            ADDR   : next_state = (counter == ADDR_WIDTH-1) ? (mode ? WDATA : SREADY) : ADDR;
            SREADY : next_state = mode ? IDLE : (SPLIT_EN ? SPLIT : RVALID);
            RVALID : next_state = rvalid ? RDATA : RVALID;
            SPLIT  : next_state = (rcounter == LATENCY) ? WAIT : SPLIT;
            WAIT   : next_state = split_grant ? RDATA : (stuck_hit ? IDLE : WAIT);
            RDATA  : next_state = (counter == DATA_WIDTH*2) ? IDLE : RDATA;
            WDATA  : next_state = (counter == DATA_WIDTH-1) ? SREADY : WDATA;
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state      <= IDLE;
            prev_state <= IDLE;
        end else begin
            prev_state <= state;
            state      <= next_state;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn)                                  stuck <= '0;
        else if (state == SPLIT || state == WAIT)   stuck <= stuck + 1'b1;
        else                                        stuck <= '0;
    end

    assign rdata  = smemrdata;
    assign sready = (state == IDLE);
    assign ssplit = (state == SPLIT);

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wdata     <= '0;
            addr      <= '0;
            counter   <= '0;
            svalid    <= 1'b0;
            smemren   <= 1'b0;
            smemwen   <= 1'b0;
            mode      <= 1'b0;
            smemaddr  <= '0;
            smemwdata <= '0;
            srdata    <= 1'b0;
            rcounter  <= '0;
        end else begin
            unique case (state)
                IDLE: begin
                    counter <= '0;
                    svalid  <= 1'b0;
                    smemren <= 1'b0;
                    smemwen <= 1'b0;
                    if (mvalid) begin  // first address bit lands here
                        mode          <= smode;
                        addr[counter] <= swdata;
                        counter       <= counter + 1;
                    end
                end

                ADDR: begin
                    svalid <= 1'b0;
                    if (mvalid) begin
                        addr[counter] <= swdata;
                        counter <= (counter == ADDR_WIDTH-1) ? '0 : counter + 1;
                    end
                end

                SREADY: begin
                    svalid <= 1'b0;
                    if (mode) begin
                        smemwen   <= 1'b1;
                        smemwdata <= wdata;
                        smemaddr  <= addr;
                    end else begin
                        smemren  <= 1'b1;
                        smemaddr <= addr;
                    end
                end

                RVALID: smemren <= 1'b1;  // hold ren until data valid

                SPLIT: begin
                    rcounter <= rcounter + 1;
                    smemren  <= 1'b1;
                end

                WAIT: begin
                    rcounter <= '0;
                    smemren  <= 1'b1;
                end

                RDATA: begin  // 2 cycles per bit: load then valid
                    if (counter < DATA_WIDTH*2) begin
                        if (counter[0] == 1'b0) begin
                            srdata <= rdata[counter >> 1];
                            svalid <= 1'b0;
                        end else begin
                            svalid <= 1'b1;
                        end
                        smemren <= 1'b1;
                        counter <= counter + 1;
                    end else begin
                        svalid  <= 1'b0;
                        smemren <= 1'b0;
                        counter <= '0;
                    end
                end

                WDATA: begin
                    svalid <= 1'b0;
                    // skip first cycle after ADDR, master inserts setup gap
                    if (mvalid && !(prev_state == ADDR)) begin
                        wdata[counter] <= swdata;
                        // wen gets set in SREADY together with addr
                        counter <= (counter == DATA_WIDTH-1) ? '0 : counter + 1;
                    end
                end

                default: ;
            endcase
        end
    end

endmodule
