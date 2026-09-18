`timescale 1ns/1ps
//=============================================================================
// Sytembus_top
//
// Wrapper holding the Sytembus fabric and the JTAG In-System Sources and
// Probes instance. Both master device ports are driven from JTAG, so the bus
// and its arbiter can be exercised from the laptop with nothing attached to
// the board except the USB-Blaster.
//
// Remote access is no longer a side channel on master 1. It is an address:
// either master reaches the far board by aiming at the bridge node, so the
// old d1_remote source bit is gone. Source/probe widths are unchanged so the
// Jtag IP does not need regenerating.
//
//   jtag source (53 bits, laptop -> fabric)
//     [15:0]  d1_addr
//     [23:16] d1_wdata
//     [24]    d1_valid
//     [25]    d1_mode
//     [41:26] d2_addr
//     [49:42] d2_wdata
//     [50]    d2_valid
//     [51]    d2_mode
//     [52]    DIAG switch: while 1, the two rdata bytes on the probe are
//             replaced by the 16 bit bus status word (see Sytembus.dbg).
//             The console's 'diag' command drives this.
//
//   jtag probe (19 bits, fabric -> laptop)
//     [7:0]   d1_rdata
//     [8]     d1_ready
//     [16:9]  d2_rdata
//     [17]    d2_ready
//     [18]    br_error   (far board did not answer a read in time)
//
//   address map, same on both boards
//     0x0000-0x07FF local S1 2K    0x8000-0x87FF far S1
//     0x1000-0x1FFF local S2 4K    0x9000-0x9FFF far S2
//     0x2000-0x2FFF local S3 4K    0xA000-0xAFFF far S3  (split on read)
//=============================================================================

module Sytembus_top #(
    parameter ADDR_WIDTH            = 16,
    parameter DATA_WIDTH            = 8,
    parameter SLAVE1_MEM_ADDR_WIDTH = 11,
    parameter SLAVE2_MEM_ADDR_WIDTH = 12,
    parameter SLAVE3_MEM_ADDR_WIDTH = 12,
    parameter CLKS_PER_BIT          = 434,    // 50MHz / 115200, board to board link
    parameter RESP_TIMEOUT          = 500000  // 10ms @ 50MHz
)(
    input  logic clk,
    input  logic rstn,

    // board to board link, the only uart on the design
    input  logic rm_rx,
    output logic rm_tx
);

    // jtag <-> device port wires
    logic [52:0] jtag_source;
    logic [18:0] jtag_probe;

    logic [ADDR_WIDTH-1:0] d1_addr;
    logic [DATA_WIDTH-1:0] d1_wdata;
    logic [DATA_WIDTH-1:0] d1_rdata;
    logic                  d1_valid;
    logic                  d1_ready;
    logic                  d1_mode;

    logic [ADDR_WIDTH-1:0] d2_addr;
    logic [DATA_WIDTH-1:0] d2_wdata;
    logic [DATA_WIDTH-1:0] d2_rdata;
    logic                  d2_valid;
    logic                  d2_ready;
    logic                  d2_mode;

    logic                  br_error;
    logic [15:0]           dbg;
    logic                  diag;

    // ------------------------------------------------------------------
    // CLOCK DOMAIN CROSSING
    //
    // The ISSP source register is written from the laptop and lives in the
    // JTAG TCK domain, and the megafunction is generated with
    // enable_metastability = "NO". Wiring those bits straight into
    // master_port samples an asynchronous signal: dvalid can go metastable,
    // and different source bits can be seen changing on different clk edges.
    //
    // A single phase transaction survives that. A SPLIT does not: the master
    // can restart in the middle of the ssplit / split_grant handshake, the
    // reconnect is lost, and the master hangs until KEY[0]. That is why only
    // slave 3 misbehaved on the board while slaves 1 and 2 were fine.
    //
    // Two flops on the whole source word. addr/wdata/mode are stable for
    // milliseconds before valid rises, so delaying them equally costs
    // nothing and keeps the fields coherent.
    // ------------------------------------------------------------------
    logic [52:0] src_meta, src_sync;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            src_meta <= '0;
            src_sync <= '0;
        end else begin
            src_meta <= jtag_source;
            src_sync <= src_meta;
        end
    end

    // m1: source drives the bus
    assign d1_addr  = src_sync[15:0];
    assign d1_wdata = src_sync[23:16];
    assign d1_valid = src_sync[24];
    assign d1_mode  = src_sync[25];

    // diag switch, synchronised with the rest of the source word. It does two
    // things at once: it swaps the two rdata bytes on the probe for the bus
    // status word, and it closes an INTERNAL LOOPBACK around the link, tying
    // the bridge's receiver to its own transmitter inside the fpga.
    //
    // That second job is what separates "our design is broken" from "the pins
    // or the wire are broken". With the loopback closed, a far access never
    // touches PIN_D3 or PIN_C3 or any cable, so if it works the whole link
    // stack is proven and every remaining fault is physical. The console's
    // 'selftest' command drives this.
    assign diag = src_sync[52];

    logic rm_tx_i;
    assign rm_tx = rm_tx_i;

    // m1: bus drives the probe (or the low status byte in diag mode)
    assign jtag_probe[7:0] = diag ? dbg[7:0] : d1_rdata;
    assign jtag_probe[8]   = d1_ready;
    assign jtag_probe[18]  = br_error;

    // m2: source drives the bus
    assign d2_addr  = src_sync[41:26];
    assign d2_wdata = src_sync[49:42];
    assign d2_valid = src_sync[50];
    assign d2_mode  = src_sync[51];

    // m2: bus drives the probe (or the high status byte in diag mode)
    assign jtag_probe[16:9] = diag ? dbg[15:8] : d2_rdata;
    assign jtag_probe[17]   = d2_ready;

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
        .CLKS_PER_BIT          (CLKS_PER_BIT),
        .RESP_TIMEOUT          (RESP_TIMEOUT)
    ) u_bus (
        .clk      (clk),
        .rstn     (rstn),

        .d1_addr  (d1_addr),
        .d1_wdata (d1_wdata),
        .d1_rdata (d1_rdata),
        .d1_valid (d1_valid),
        .d1_ready (d1_ready),
        .d1_mode  (d1_mode),

        .d2_addr  (d2_addr),
        .d2_wdata (d2_wdata),
        .d2_rdata (d2_rdata),
        .d2_valid (d2_valid),
        .d2_ready (d2_ready),
        .d2_mode  (d2_mode),

        .rm_rx    (diag ? rm_tx_i : rm_rx),
        .rm_tx    (rm_tx_i),

        .br_error (br_error),
        .dbg      (dbg)
    );

endmodule
