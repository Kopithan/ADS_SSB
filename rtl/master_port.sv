`timescale 1ns/1ps

module master_port #(
    parameter ADDR_WIDTH           = 16,
    parameter DATA_WIDTH           = 8,
    parameter SLAVE_MEM_ADDR_WIDTH = 12,
    // Escape hatch for RDATA and SPLIT, the only states with no counter of
    // their own. If a svalid or a split reconnect is ever lost, the master
    // would otherwise sit there forever and the whole bus is dead until the
    // reset button. Must be comfortably longer than the slowest legitimate
    // split: the uart bridge holds one for RESP_TIMEOUT (500k) cycles.
    parameter STUCK_TIMEOUT        = 2000000
)(
    input  logic clk,
    input  logic rstn,

    // master device side
    input  logic [DATA_WIDTH-1:0] dwdata,
    output logic [DATA_WIDTH-1:0] drdata,
    input  logic [ADDR_WIDTH-1:0] daddr,
    input  logic                  dvalid,
    output logic                  dready,
    input  logic                  dmode,     // 0 read, 1 write

    // serial bus side
    input  logic mrdata,
    output logic mwdata,
    output logic mmode,
    output logic mvalid,
    input  logic svalid,

    // arbiter side
    output logic mbreq,
    input  logic mbgrant,
    input  logic msplit,

    // decoder ack
    input  logic ack,

    // static snapshot for the JTAG diag word
    output logic [2:0] dbg_state
);

    localparam SLAVE_DEVICE_ADDR_WIDTH = ADDR_WIDTH - SLAVE_MEM_ADDR_WIDTH;
    localparam TIMEOUT_TIME = 5;
    localparam STUCK_W      = $clog2(STUCK_TIMEOUT+1);

    // latched transaction
    logic [DATA_WIDTH-1:0] wdata;
    logic [ADDR_WIDTH-1:0] addr;
    logic                  mode;
    logic [DATA_WIDTH-1:0] rdata;

    logic [7:0] counter, timeout;
    logic [STUCK_W-1:0] stuck;      // watchdog for RDATA and SPLIT
    logic               stuck_hit;

    assign stuck_hit = (stuck == STUCK_TIMEOUT[STUCK_W-1:0]);

    typedef enum logic [2:0] {
        IDLE  = 3'b000,
        ADDR  = 3'b001,   // send mem address
        RDATA = 3'b010,
        WDATA = 3'b011,
        REQ   = 3'b100,
        SADDR = 3'b101,   // send device id
        WAIT  = 3'b110,   // wait for ack
        SPLIT = 3'b111
    } state_t;

    state_t state, next_state, prev_state;

    // next state
    always_comb begin
        unique case (state)
            IDLE  : next_state = dvalid  ? REQ   : IDLE;
            REQ   : next_state = mbgrant ? SADDR : REQ;
            SADDR : next_state = (counter == SLAVE_DEVICE_ADDR_WIDTH-1) ? WAIT : SADDR;
            WAIT  : next_state = ack ? ADDR : ((timeout == TIMEOUT_TIME) ? IDLE : WAIT);
            ADDR  : next_state = (counter == SLAVE_MEM_ADDR_WIDTH-1) ? (mode ? WDATA : RDATA) : ADDR;
            RDATA : next_state = msplit ? SPLIT :
                                 ((svalid && (counter == DATA_WIDTH-1)) || stuck_hit) ? IDLE : RDATA;
            WDATA : next_state = (counter == DATA_WIDTH-1) ? IDLE : WDATA;
            SPLIT : next_state = (!msplit && mbgrant) ? RDATA : (stuck_hit ? IDLE : SPLIT);
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

    assign dready    = (state == IDLE);
    assign dbg_state = state;
    assign drdata = rdata;
    assign mmode  = mode;
    assign mbreq  = (state != IDLE);  // hold request while busy

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn)                                    stuck <= '0;
        else if (state == RDATA || state == SPLIT)    stuck <= stuck + 1'b1;
        else                                          stuck <= '0;
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wdata   <= '0;
            rdata   <= '0;
            addr    <= '0;
            mode    <= 1'b0;
            counter <= '0;
            mvalid  <= 1'b0;
            mwdata  <= 1'b0;
            timeout <= '0;
        end else begin
            unique case (state)
                IDLE: begin
                    counter <= '0;
                    mvalid  <= 1'b0;
                    timeout <= '0;
                    if (dvalid) begin
                        wdata <= dwdata;
                        addr  <= daddr;
                        mode  <= dmode;
                        // rdata keeps old result until next read
                    end
                end

                REQ: ; // just waiting for grant

                SADDR: begin  // device id, bits [15:12], LSB first
                    mwdata <= addr[SLAVE_MEM_ADDR_WIDTH + counter];
                    mvalid <= 1'b1;
                    counter <= (counter == SLAVE_DEVICE_ADDR_WIDTH-1) ? '0 : counter + 1;
                end

                WAIT: begin
                    mvalid  <= 1'b0;
                    timeout <= timeout + 1;
                end

                ADDR: begin  // mem address, LSB first
                    mwdata <= addr[counter];
                    mvalid <= 1'b1;
                    counter <= (counter == SLAVE_MEM_ADDR_WIDTH-1) ? '0 : counter + 1;
                end

                RDATA: begin
                    mvalid <= 1'b0;
                    if (svalid) begin
                        rdata[counter] <= mrdata;
                        counter <= (counter == DATA_WIDTH-1) ? '0 : counter + 1;
                    end
                end

                WDATA: begin
                    // one setup cycle after ADDR so slave can catch up
                    if (prev_state == ADDR) begin
                        mvalid <= 1'b0;
                        mwdata <= 1'b0;
                    end else begin
                        mwdata <= wdata[counter];
                        mvalid <= 1'b1;
                        counter <= (counter == DATA_WIDTH-1) ? '0 : counter + 1;
                    end
                end

                SPLIT: mvalid <= 1'b0;

                default: ;
            endcase
        end
    end

endmodule
