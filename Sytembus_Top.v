`timescale 1ns/1ps
//=============================================================================
// Sytembus_top
//
// Wrapper holding the Sytembus fabric and the JTAG In-System Sources and
// Probes instance. Master 1's device port is driven entirely from JTAG, so
// the bus can be exercised from the laptop with nothing attached to the board
// except the USB-Blaster.
//
// Only clk, rstn and the four UART pins need pin assignments.
//
//   Jtag source (26 bits, laptop -> fabric)
//     [15:0]  d1_addr
//     [23:16] d1_wdata
//     [24]    d1_valid
//     [25]    d1_mode
//
//   Jtag probe (9 bits, fabric -> laptop)
//     [7:0]   d1_rdata
//     [8]     d1_ready
//=============================================================================

module Sytembus_top #(
    parameter ADDR_WIDTH            = 16,
    parameter DATA_WIDTH            = 8,
    parameter SLAVE1_MEM_ADDR_WIDTH = 11,
    parameter SLAVE2_MEM_ADDR_WIDTH = 12,
    parameter SLAVE3_MEM_ADDR_WIDTH = 12,
    parameter UART_CLOCKS_PER_PULSE = 5208    // 50MHz / 9600
)(
    input  logic clk,
    input  logic rstn,

    // bridge master uart (remote commands in)
    input  logic bm_rx,
    output logic bm_tx,

    // bridge slave uart (to remote bus)
    input  logic bs_rx,
    output logic bs_tx
);

    // jtag <-> device port wires
    logic [25:0] jtag_source;
    logic [8:0]  jtag_probe;

    logic [ADDR_WIDTH-1:0] d1_addr;
    logic [DATA_WIDTH-1:0] d1_wdata;
    logic [DATA_WIDTH-1:0] d1_rdata;
    logic                  d1_valid;
    logic                  d1_ready;
    logic                  d1_mode;

    // source drives the bus
    assign d1_addr  = jtag_source[15:0];
    assign d1_wdata = jtag_source[23:16];
    assign d1_valid = jtag_source[24];
    assign d1_mode  = jtag_source[25];

    // bus drives the probe
    assign jtag_probe[7:0] = d1_rdata;
    assign jtag_probe[8]   = d1_ready;

    Jtag u_jtag (
        .source (jtag_source),
        .probe  (jtag_probe)
    );

    Sytembus #(
        .ADDR_WIDTH            (ADDR_WIDTH),
        .DATA_WIDTH            (DATA_WIDTH),
        .SLAVE1_MEM_ADDR_WIDTH (SLAVE1_MEM_ADDR_WIDTH),
        .SLAVE2_MEM_ADDR_WIDTH (SLAVE2_MEM_ADDR_WIDTH),
        .SLAVE3_MEM_ADDR_WIDTH (SLAVE3_MEM_ADDR_WIDTH),
        .UART_CLOCKS_PER_PULSE (UART_CLOCKS_PER_PULSE)
    ) u_bus (
        .clk      (clk),
        .rstn     (rstn),

        .d1_addr  (d1_addr),
        .d1_wdata (d1_wdata),
        .d1_rdata (d1_rdata),
        .d1_valid (d1_valid),
        .d1_ready (d1_ready),
        .d1_mode  (d1_mode),

        .bm_rx    (bm_rx),
        .bm_tx    (bm_tx),
        .bs_rx    (bs_rx),
        .bs_tx    (bs_tx)
    );

endmodule