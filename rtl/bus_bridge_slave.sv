`timescale 1ns/1ps

// slave 3: local BRAM for low half, forwards upper half over UART.
// reads over uart use the split mechanism
module bus_bridge_slave #(
    parameter DATA_WIDTH            = 8,
    parameter ADDR_WIDTH            = 12,
    parameter UART_CLOCKS_PER_PULSE = 5208,
    parameter LOCAL_MEM_SIZE        = 2048,
    parameter BRIDGE_ENABLE         = 1
)(
    input  logic clk,
    input  logic rstn,

    // local serial bus
    input  logic swdata,
    input  logic smode,
    input  logic mvalid,
    input  logic split_grant,
    output logic srdata,
    output logic svalid,
    output logic sready,
    output logic ssplit,

    // uart to remote
    output logic u_tx,
    input  logic u_rx
);

    localparam UART_TX_DATA_WIDTH = DATA_WIDTH + ADDR_WIDTH + 1;  // mode+data+addr out
    localparam UART_RX_DATA_WIDTH = DATA_WIDTH;                   // read byte in
    localparam SPLIT_EN           = 1'b1;
    localparam LOCAL_ADDR_MSB     = ADDR_WIDTH - 1;  // msb: 0 local, 1 bridge

    // slave port <-> controller
    logic [DATA_WIDTH-1:0] sp_memrdata, sp_memwdata;
    logic [ADDR_WIDTH-1:0] sp_memaddr;
    logic sp_memwen, sp_memren, sp_rvalid, sp_ready;

    // local mem
    logic lmem_wen, lmem_ren, lmem_rvalid;
    logic [ADDR_WIDTH-2:0] lmem_addr;
    logic [DATA_WIDTH-1:0] lmem_rdata;

    // uart
    logic [UART_TX_DATA_WIDTH-1:0] u_din;
    logic u_en, u_tx_busy, u_rx_ready;
    logic [UART_RX_DATA_WIDTH-1:0] u_dout;

    // controller
    logic [DATA_WIDTH-1:0] latched_rdata, latched_wdata;
    logic [ADDR_WIDTH-1:0] latched_addr;
    logic rdata_received, prev_u_rx_ready;
    logic pending_write, pending_read;
    logic is_local_access, is_local_access_now;
	 
	 assign is_local_access_now = sp_memaddr[LOCAL_ADDR_MSB];
    assign is_local_access     = latched_addr[LOCAL_ADDR_MSB];


    // gate the local BRAM with the address that is on the port RIGHT NOW.
    // latched_addr / is_local_access only update one cycle after sp_memwen
    // rises, so on the first local access after reset (or after a bridged
    // access) the latched copy is stale and a one-cycle write pulse is lost.
    assign lmem_wen  = sp_memwen & is_local_access_now;
    assign lmem_ren  = sp_memren & is_local_access_now;
    assign lmem_addr = sp_memaddr[ADDR_WIDTH-2:0];

    logic sp_split_grant, sp_ssplit;

    slave_port #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN  (SPLIT_EN)
    ) slave (
        .clk(clk), .rstn(rstn),
        .smemrdata(sp_memrdata), .rvalid(sp_rvalid),
        .smemwen(sp_memwen), .smemren(sp_memren),
        .smemaddr(sp_memaddr), .smemwdata(sp_memwdata),
        .swdata(swdata), .srdata(srdata), .smode(smode),
        .mvalid(mvalid), .split_grant(sp_split_grant),
        .svalid(svalid), .sready(sp_ready), .ssplit(sp_ssplit)
    );

    slave_memory_bram #(
        .ADDR_WIDTH(ADDR_WIDTH-1),
        .DATA_WIDTH(DATA_WIDTH),
        .MEM_SIZE  (LOCAL_MEM_SIZE)
    ) local_mem (
        .clk(clk), .rstn(rstn),
        .wen(lmem_wen), .ren(lmem_ren), .addr(lmem_addr),
        .wdata(sp_memwdata), .rdata(lmem_rdata), .rvalid(lmem_rvalid)
    );

    uart #(
        .CLOCKS_PER_PULSE(UART_CLOCKS_PER_PULSE),
        .TX_DATA_WIDTH(UART_TX_DATA_WIDTH),
        .RX_DATA_WIDTH(UART_RX_DATA_WIDTH)
    ) uart_module (
        .clk(clk), .rstn(rstn),
        .data_input(u_din), .data_en(u_en),
        .tx(u_tx), .tx_busy(u_tx_busy),
        .rx(u_rx), .ready(u_rx_ready), .data_output(u_dout)
    );

    // controller fsm
    typedef enum logic [2:0] {
        IDLE  = 3'b000,
        WSEND = 3'b001,
        RSEND = 3'b010,
        RDATA = 3'b011,
        LOCAL = 3'b100,
        WBUSY = 3'b101,
        RBUSY = 3'b110
    } state_t;

    state_t state, next_state;

    logic bridge_read_in_progress;
    assign bridge_read_in_progress = (state == RSEND) || (state == RBUSY) || (state == RDATA);
    // only release split once the remote actually answered
    assign sp_split_grant = bridge_read_in_progress ? (split_grant && rdata_received) : split_grant;
    assign ssplit = sp_ssplit || (bridge_read_in_progress && !rdata_received);

    logic prev_sp_memwen, prev_sp_memren;

    // latch request on wen/ren rising edge
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            latched_wdata  <= '0;
            latched_addr   <= '0;
            pending_write  <= 1'b0;
            pending_read   <= 1'b0;
            prev_sp_memwen <= 1'b0;
            prev_sp_memren <= 1'b0;
        end else begin
            prev_sp_memwen <= sp_memwen;
            prev_sp_memren <= sp_memren;

            if (sp_memwen && !prev_sp_memwen && state == IDLE) begin
                latched_wdata <= sp_memwdata;
                latched_addr  <= sp_memaddr;
                if (!sp_memaddr[LOCAL_ADDR_MSB] && BRIDGE_ENABLE[0])
                     pending_write <= 1'b1;
            end else if (sp_memren && !prev_sp_memren && state == IDLE) begin
                latched_addr <= sp_memaddr;
					 if (!sp_memaddr[LOCAL_ADDR_MSB] && BRIDGE_ENABLE[0])
                    pending_read <= 1'b1;   
            end else if (state == WSEND || state == RSEND) begin
                pending_write <= 1'b0;
                pending_read  <= 1'b0;
            end
        end
    end

    // remember tx actually started so we don't leave WBUSY early
    logic uart_tx_started;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn)                                          uart_tx_started <= 1'b0;
        else if (state == WSEND || state == RSEND)          uart_tx_started <= 1'b0;
        else if ((state == WBUSY || state == RBUSY) && u_tx_busy) uart_tx_started <= 1'b1;
        else if (state == IDLE)                             uart_tx_started <= 1'b0;
    end

    always_comb begin
        unique case (state)
            IDLE: begin
                if      (pending_write) next_state = WSEND;
                else if (pending_read)  next_state = RSEND;
                else if ((sp_memwen || sp_memren) && is_local_access_now) next_state = LOCAL;
                else next_state = IDLE;
            end
            WSEND: next_state = WBUSY;
            WBUSY: next_state = (uart_tx_started && !u_tx_busy) ? IDLE  : WBUSY;
            RSEND: next_state = RBUSY;
            RBUSY: next_state = (uart_tx_started && !u_tx_busy) ? RDATA : RBUSY;
            RDATA: next_state = (!sp_memren) ? IDLE : RDATA;
            LOCAL: next_state = (!sp_memwen && !sp_memren) ? IDLE : LOCAL;
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) state <= IDLE;
        else       state <= next_state;
    end

    // latch the uart answer
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            latched_rdata   <= '0;
            rdata_received  <= 1'b0;
            prev_u_rx_ready <= 1'b0;
        end else begin
            prev_u_rx_ready <= u_rx_ready;
            if (state == IDLE) begin
                rdata_received <= 1'b0;
                latched_rdata  <= '0;
            end else if (state == RDATA && u_rx_ready && !prev_u_rx_ready) begin
                latched_rdata  <= u_dout;
                rdata_received <= 1'b1;
            end
        end
    end

    // uart tx control, one-shot enable in WSEND/RSEND
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            u_din <= '0;
            u_en  <= 1'b0;
        end else begin
            unique case (state)
                WSEND: begin
                    u_din <= {1'b1, latched_wdata, latched_addr};  // write frame
                    u_en  <= 1'b1;
                end
                RSEND: begin
                    u_din <= {1'b0, {DATA_WIDTH{1'b0}}, latched_addr};  // read frame
                    u_en  <= 1'b1;
                end
                default: u_en <= 1'b0;
            endcase
        end
    end

    // pick where read data comes from
    assign sp_memrdata = (state == RDATA) ? (rdata_received ? latched_rdata : u_dout) :
                         (state == LOCAL) ? lmem_rdata : '0;

    always_comb begin
        if      (state == LOCAL) sp_rvalid = lmem_rvalid;
        else if (state == RDATA) sp_rvalid = rdata_received;
        else                     sp_rvalid = 1'b0;
    end

    assign sready = sp_ready && !sp_memwen && !sp_memren && (state == IDLE);

endmodule
