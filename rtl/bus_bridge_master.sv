`timescale 1ns/1ps

// takes UART commands from remote side, fires them onto the local bus
module bus_bridge_master #(
    parameter ADDR_WIDTH            = 16,
    parameter DATA_WIDTH            = 8,
    parameter SLAVE_MEM_ADDR_WIDTH  = 12,
    parameter BB_ADDR_WIDTH         = 12,
    parameter UART_CLOCKS_PER_PULSE = 5208,
    parameter LOCAL_MEM_SIZE        = 2048,
    parameter LOCAL_MEM_ADDR_WIDTH  = 11
)(
    input  logic clk,
    input  logic rstn,

    // serial bus, acting as a master
    input  logic mrdata,
    output logic mwdata,
    output logic mmode,
    output logic mvalid,
    input  logic svalid,

    // arbiter
    output logic mbreq,
    input  logic mbgrant,
    input  logic msplit,

    // decoder
    input  logic ack,

    // local BRAM poke interface
    input  logic                            lmem_wen,
    input  logic                            lmem_ren,
    input  logic [LOCAL_MEM_ADDR_WIDTH-1:0] lmem_addr,
    input  logic [DATA_WIDTH-1:0]           lmem_wdata,
    output logic [DATA_WIDTH-1:0]           lmem_rdata,
    output logic                            lmem_rvalid,

    // uart to remote
    output logic u_tx,
    input  logic u_rx
);

    localparam UART_RX_DATA_WIDTH = DATA_WIDTH + BB_ADDR_WIDTH + 1;  // mode+data+addr
    localparam UART_TX_DATA_WIDTH = DATA_WIDTH;                      // just read data back

    // master port hookup
    logic [DATA_WIDTH-1:0] dwdata;
    logic [DATA_WIDTH-1:0] drdata;
    logic [ADDR_WIDTH-1:0] daddr;
    logic                  dvalid, dready, dmode;

    // fifo
    logic fifo_enq, fifo_deq, fifo_empty, fifo_full;
    logic [UART_RX_DATA_WIDTH-1:0] fifo_din, fifo_dout;

    // uart
    logic [UART_TX_DATA_WIDTH-1:0] u_din;
    logic                          u_en, u_tx_busy, u_rx_ready;
    logic [UART_RX_DATA_WIDTH-1:0] u_dout;

    logic [BB_ADDR_WIDTH-1:0] bb_addr;
    logic expect_rdata, prev_u_ready, prev_m_ready;

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(SLAVE_MEM_ADDR_WIDTH)
    ) master (
        .clk(clk), .rstn(rstn),
        .dwdata(dwdata), .drdata(drdata), .daddr(daddr),
        .dvalid(dvalid), .dready(dready), .dmode(dmode),
        .mrdata(mrdata), .mwdata(mwdata), .mmode(mmode),
        .mvalid(mvalid), .svalid(svalid),
        .mbreq(mbreq), .mbgrant(mbgrant), .msplit(msplit),
        .ack(ack)
    );

    fifo #(.DATA_WIDTH(UART_RX_DATA_WIDTH), .DEPTH(8)) fifo_queue (
        .clk(clk), .rstn(rstn),
        .enq(fifo_enq), .deq(fifo_deq),
        .data_in(fifo_din), .data_out(fifo_dout),
        .empty(fifo_empty), .full(fifo_full)
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

    addr_convert #(
        .BB_ADDR_WIDTH(BB_ADDR_WIDTH),
        .BUS_ADDR_WIDTH(ADDR_WIDTH),
        .BUS_MEM_ADDR_WIDTH(SLAVE_MEM_ADDR_WIDTH)
    ) addr_convert_module (
        .bb_addr (bb_addr),
        .bus_addr(daddr)
    );

    master_memory_bram #(
        .ADDR_WIDTH(LOCAL_MEM_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .MEM_SIZE  (LOCAL_MEM_SIZE)
    ) local_mem (
        .clk(clk), .rstn(rstn),
        .wen(lmem_wen), .ren(lmem_ren), .addr(lmem_addr),
        .wdata(lmem_wdata), .rdata(lmem_rdata), .rvalid(lmem_rvalid)
    );

    // uart rx -> fifo, catch the ready edge
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            fifo_din     <= '0;
            fifo_enq     <= 1'b0;
            prev_u_ready <= 1'b0;
        end else begin
            prev_u_ready <= u_rx_ready;
            if (u_rx_ready && !prev_u_ready) begin
                fifo_din <= u_dout;
                fifo_enq <= 1'b1;
            end else
                fifo_enq <= 1'b0;
        end
    end

    // fifo -> master port, kick a transaction when idle
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            bb_addr      <= '0;
            dwdata       <= '0;
            dmode        <= 1'b0;
            dvalid       <= 1'b0;
            fifo_deq     <= 1'b0;
            expect_rdata <= 1'b0;
        end else begin
            if (dready && !fifo_empty && !dvalid) begin
                bb_addr      <= fifo_dout[BB_ADDR_WIDTH-1:0];
                dwdata       <= fifo_dout[BB_ADDR_WIDTH +: DATA_WIDTH];
                dmode        <= fifo_dout[BB_ADDR_WIDTH + DATA_WIDTH];
                dvalid       <= 1'b1;
                fifo_deq     <= 1'b1;
                expect_rdata <= ~fifo_dout[BB_ADDR_WIDTH + DATA_WIDTH];  // read? then answer later
            end else begin
                dvalid   <= 1'b0;
                fifo_deq <= 1'b0;
            end
        end
    end

    // read done -> send byte back over uart
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            u_din        <= '0;
            u_en         <= 1'b0;
            prev_m_ready <= 1'b0;
        end else begin
            prev_m_ready <= dready;
            if (!prev_m_ready && dready && expect_rdata) begin
                u_din <= drdata;
                u_en  <= 1'b1;
            end else
                u_en <= 1'b0;
        end
    end

endmodule
