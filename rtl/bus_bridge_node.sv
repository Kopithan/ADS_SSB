`timescale 1ns/1ps
//=============================================================================
// bus_bridge_node
//
// One UART link shared by the whole bus. Unlike uart_bus_master, the link is
// NOT owned by a master: this is a device sitting on the bus with two faces,
// so every local master can reach the far system and the far system can reach
// every local slave.
//
//   slave face  - device ids 8,9,10. any local master issues an ordinary bus
//                 transaction here; we pack it into a REQUEST and send it out.
//                 the far device id is id-8, handed to us on bdev because the
//                 decoder eats the device id and a slave port never sees it.
//   master face - a REQUEST arriving on the link makes us bid for the bus as
//                 a third master and run the transaction on OUR slaves.
//
// address budget. a slave port only ever shifts in MEM_ADDR_WIDTH (12) offset
// bits, so bdev supplies the missing device bits:
//
//     far address  = { 2'b00, bdev[1:0], offset[11:0] }       16 bits
//     wire address = far address[13:0]                        14 bits
//
// far addr[15:14] is always 00 because the far decoder only honours device
// ids 0..2, so 14 bits is lossless AND a request can never decode to the far
// bridge (ids 8..10). the link is structurally loop free, no hop counter.
//
// Wire protocol (fixed, must match the far board byte for byte):
//   REQUEST   0xA5, b0, b1, b2      b0=cmd[7:0] b1=cmd[15:8] b2=cmd[23:16]
//   RESPONSE  0x5A, data            READS ONLY
//   cmd = {wdata[7:0], addr[13:0], we, 1'b0}
//
// writes are posted: the local master retires as soon as the slave port has
// the byte, and no response comes back. only reads answer, so a RESPONSE is
// unambiguously the answer to the one outstanding read. reads use the split
// mechanism, and ssplit is held high for the WHOLE round trip so the bus is
// free for the other masters while we wait on the wire.
//=============================================================================

module bus_bridge_node #(
    parameter ADDR_WIDTH     = 16,
    parameter DATA_WIDTH     = 8,
    parameter MEM_ADDR_WIDTH = 12,      // offset bits the slave face shifts in
    parameter CLKS_PER_BIT   = 434,     // 50MHz / 115200
    parameter RESP_TIMEOUT   = 500000,  // 10ms @ 50MHz
    // How long an identical repeat of the last far request is treated as the
    // same logical access and answered without touching the wire. See the
    // duplicate suppression block below. Must be longer than the gap between
    // two re-issues of a held dvalid (under 1 ms) and shorter than the gap
    // between two console commands (the 10 ms drain).
    parameter DUP_WINDOW     = 250000   // 5ms @ 50MHz
)(
    input  logic clk,
    input  logic rstn,

    // slave face: local masters -> far system
    input  logic       swdata,
    input  logic       smode,
    input  logic       mvalid,
    input  logic       split_grant,
    input  logic [1:0] bdev,        // far device id, from the decoder
    output logic       srdata,
    output logic       svalid,
    output logic       sready,
    output logic       ssplit,

    // master face: far system -> local slaves
    input  logic mrdata,
    output logic mwdata,
    output logic mmode,
    output logic mmvalid,
    input  logic msvalid,
    output logic mbreq,
    input  logic mbgrant,
    input  logic msplit,
    input  logic ack,

    // the link
    output logic u_tx,
    input  logic u_rx,

    // sticky: far side did not answer in time
    output logic derror,

    // static snapshot for the JTAG diag word: client fsm not idle, and two
    // sticky flags cleared when our client sends a request: did ANY byte
    // arrive on rm_rx since, and did a RESPONSE (0x5A) frame arrive since.
    // Together they separate "far side silent", "far side talks but not in
    // our frame format" and "answer came, we did not accept it".
    output logic dbg_busy,
    output logic dbg_rx_any,
    output logic dbg_resp_seen,

    // Physical layer evidence, all sticky and all cleared when our client
    // sends a request, so they describe the LAST far access:
    //   dbg_req_sent - our 4 request bytes finished leaving the transmitter
    //   dbg_tx_ran   - the uart transmitter actually ran at all
    //   dbg_rx_low   - rm_rx was seen LOW at least once. This sits below the
    //                  framing: it is true if any start bit, or any electrical
    //                  activity whatsoever, reached the pin. With a loopback
    //                  jumper it must be true; if it is false the wire is not
    //                  carrying our own transmitter back to us.
    output logic dbg_req_sent,
    output logic dbg_tx_ran,
    output logic dbg_rx_low,

    // LIVE level of rm_rx right now, synchronised, not sticky. This is a DC
    // measurement of the pin with no uart involved at all: tie rm_rx to a
    // ground pin with a wire and this must read 0. It is the simplest
    // possible continuity test of the receive path.
    output logic dbg_rx_level
);

    localparam [7:0] TAG_REQ  = 8'hA5;
    localparam [7:0] TAG_RESP = 8'h5A;
    localparam       RADDR_W  = 14;          // address bits carried on the wire
    localparam [7:0] ERR_DATA = 8'hFF;       // returned on timeout
    localparam       TMO_W    = $clog2(RESP_TIMEOUT+1);

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH != 8)
            $fatal(1, "bus_bridge_node: byte based wire protocol needs DATA_WIDTH=8");
        if (MEM_ADDR_WIDTH + 2 != RADDR_W)
            $fatal(1, "bus_bridge_node: bdev+offset must fill the 14 bit wire address");
    end
    // synthesis translate_on

    // ------------------------------------------------------------------
    // slave face
    // ------------------------------------------------------------------
    logic [DATA_WIDTH-1:0]     sp_memrdata, sp_memwdata;
    logic [MEM_ADDR_WIDTH-1:0] sp_memaddr;
    logic sp_memwen, sp_memren, sp_rvalid, sp_ready;
    logic sp_split_grant, sp_ssplit;

    slave_port #(
        .ADDR_WIDTH(MEM_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SPLIT_EN  (1)
    ) sface (
        .clk(clk), .rstn(rstn),
        .smemrdata(sp_memrdata), .rvalid(sp_rvalid),
        .smemwen(sp_memwen), .smemren(sp_memren),
        .smemaddr(sp_memaddr), .smemwdata(sp_memwdata),
        .swdata(swdata), .srdata(srdata), .smode(smode),
        .mvalid(mvalid), .split_grant(sp_split_grant),
        .svalid(svalid), .sready(sp_ready), .ssplit(sp_ssplit)
    );

    // ------------------------------------------------------------------
    // master face
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] mp_daddr;
    logic [DATA_WIDTH-1:0] mp_dwdata, mp_drdata;
    logic                  mp_dvalid, mp_dready, mp_dmode;

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(MEM_ADDR_WIDTH)
    ) mface (
        .clk(clk), .rstn(rstn),
        .dwdata(mp_dwdata), .drdata(mp_drdata), .daddr(mp_daddr),
        .dvalid(mp_dvalid), .dready(mp_dready), .dmode(mp_dmode),
        .mrdata(mrdata), .mwdata(mwdata), .mmode(mmode),
        .mvalid(mmvalid), .svalid(msvalid),
        .mbreq(mbreq), .mbgrant(mbgrant), .ack(ack), .msplit(msplit)
    );

    // ------------------------------------------------------------------
    // byte level uart, 8N1
    // ------------------------------------------------------------------
    logic [7:0] u_din, u_dout;
    logic       u_en, u_tx_busy, u_rx_ready;

    uart #(
        .CLOCKS_PER_PULSE(CLKS_PER_BIT),
        .TX_DATA_WIDTH(8),
        .RX_DATA_WIDTH(8)
    ) link (
        .clk(clk), .rstn(rstn),
        .data_input(u_din), .data_en(u_en),
        .tx(u_tx), .tx_busy(u_tx_busy),
        .rx(u_rx), .data_output(u_dout), .ready(u_rx_ready)
    );

    logic u_rx_ready_q, rx_stb;
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) u_rx_ready_q <= 1'b0;
        else       u_rx_ready_q <= u_rx_ready;
    end
    assign rx_stb = u_rx_ready & ~u_rx_ready_q;

    // ------------------------------------------------------------------
    // receive parser: hunt for a tag, then take exactly 3 or exactly 1 more.
    // a payload byte equal to a tag value is therefore never misread.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {R_TAG = 2'd0, R_REQ = 2'd1, R_RESP = 2'd2} rx_state_t;
    rx_state_t rx_state;

    logic [1:0]  rx_cnt;
    logic [23:0] rx_cmd;
    logic        req_stb, resp_stb;
    logic [7:0]  resp_byte;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rx_state  <= R_TAG;
            rx_cnt    <= '0;
            rx_cmd    <= '0;
            req_stb   <= 1'b0;
            resp_stb  <= 1'b0;
            resp_byte <= '0;
        end else begin
            req_stb  <= 1'b0;
            resp_stb <= 1'b0;
            if (rx_stb) begin
                unique case (rx_state)
                    R_TAG: begin
                        if      (u_dout == TAG_REQ)  begin rx_cnt <= '0; rx_state <= R_REQ; end
                        else if (u_dout == TAG_RESP) rx_state <= R_RESP;
                        // anything else: keep hunting
                    end

                    R_REQ: begin
                        rx_cmd <= {u_dout, rx_cmd[23:8]};   // b0 arrives first, ends in [7:0]
                        if (rx_cnt == 2'd2) begin
                            req_stb  <= 1'b1;
                            rx_state <= R_TAG;
                        end else
                            rx_cnt <= rx_cnt + 1'b1;
                    end

                    R_RESP: begin
                        resp_byte <= u_dout;
                        resp_stb  <= 1'b1;
                        rx_state  <= R_TAG;
                    end

                    default: rx_state <= R_TAG;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // transmit side. two sources, RESPONSES WIN.
    // if both boards fire a remote read at once, each is waiting for a reply
    // while holding one to send; letting requests win deadlocks both.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {T_IDLE, T_LOAD, T_START, T_WAIT} tx_state_t;
    tx_state_t tx_state;

    logic [7:0]  tx_buf [0:3];
    logic [2:0]  tx_len, tx_idx;
    logic        tx_is_resp;
    logic        req_pend, resp_pend;
    logic [23:0] req_cmd;
    logic [7:0]  resp_data;
    logic        req_set, req_ack, resp_set, resp_ack;

    logic tx_done;
    assign tx_done  = (tx_state == T_WAIT) && !u_tx_busy && (tx_idx == tx_len - 3'd1);
    assign resp_ack = tx_done &&  tx_is_resp;
    assign req_ack  = tx_done && !tx_is_resp;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            tx_state   <= T_IDLE;
            tx_len     <= '0;
            tx_idx     <= '0;
            tx_is_resp <= 1'b0;
            u_din      <= '0;
            u_en       <= 1'b0;
            tx_buf[0]  <= '0;
            tx_buf[1]  <= '0;
            tx_buf[2]  <= '0;
            tx_buf[3]  <= '0;
        end else begin
            unique case (tx_state)
                T_IDLE: begin
                    u_en   <= 1'b0;
                    tx_idx <= '0;
                    if (resp_pend) begin                 // priority
                        tx_buf[0]  <= TAG_RESP;
                        tx_buf[1]  <= resp_data;
                        tx_len     <= 3'd2;
                        tx_is_resp <= 1'b1;
                        tx_state   <= T_LOAD;
                    end else if (req_pend) begin
                        tx_buf[0]  <= TAG_REQ;
                        tx_buf[1]  <= req_cmd[7:0];
                        tx_buf[2]  <= req_cmd[15:8];
                        tx_buf[3]  <= req_cmd[23:16];
                        tx_len     <= 3'd4;
                        tx_is_resp <= 1'b0;
                        tx_state   <= T_LOAD;
                    end
                end

                T_LOAD: begin
                    u_din    <= tx_buf[tx_idx];
                    u_en     <= 1'b1;
                    tx_state <= T_START;
                end

                T_START: begin
                    u_en <= 1'b0;                        // one shot
                    if (u_tx_busy) tx_state <= T_WAIT;
                end

                T_WAIT: begin
                    if (!u_tx_busy) begin
                        if (tx_idx == tx_len - 3'd1)
                            tx_state <= T_IDLE;
                        else begin
                            tx_idx   <= tx_idx + 3'd1;
                            tx_state <= T_LOAD;
                        end
                    end
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            req_pend  <= 1'b0;
            resp_pend <= 1'b0;
        end else begin
            if      (req_set)  req_pend  <= 1'b1;
            else if (req_ack)  req_pend  <= 1'b0;

            if      (resp_set) resp_pend <= 1'b1;
            else if (resp_ack) resp_pend <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // client: local bus transaction -> link -> answer
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {C_IDLE, C_SEND, C_WAIT, C_DONE} c_state_t;
    c_state_t c_state;

    logic [TMO_W-1:0]      tmo;
    logic [DATA_WIDTH-1:0] rd_data;
    logic                  rdata_received, is_read;
    logic                  prev_wen, prev_ren;
    logic                  wen_rise, ren_rise, c_timeout;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            prev_wen <= 1'b0;
            prev_ren <= 1'b0;
        end else begin
            prev_wen <= sp_memwen;
            prev_ren <= sp_memren;
        end
    end

    assign wen_rise  = sp_memwen & ~prev_wen & (c_state == C_IDLE);
    assign ren_rise  = sp_memren & ~prev_ren & (c_state == C_IDLE);
    assign c_timeout = (c_state != C_IDLE) && (tmo == RESP_TIMEOUT[TMO_W-1:0]);

    // ------------------------------------------------------------------
    // DUPLICATE REQUEST SUPPRESSION
    //
    // dvalid on a master device port is a LEVEL, not a pulse. The JTAG
    // console holds it for 20 ms, so master_port re-issues the same
    // transaction for the whole window. For a local slave that is harmless.
    // For a far access every re-issue would put another frame on the wire:
    // measured at 59 copies, 236 bytes, for ONE console write at 115200
    // baud. That is abusive to the link, and it is what a far board with no
    // receive fifo chokes on - bytes keep arriving while its server is busy
    // running the previous one, it drops one mid frame, and its parser is
    // then permanently out of frame. From then on nothing we send lands.
    //
    // A WRITE byte-identical to the previous request, arriving while the
    // window is still open, is completed locally and never reaches the wire.
    // A write is idempotent, so dropping a repeat of it cannot change what
    // ends up in the far memory. Every request restarts the window, so a
    // held dvalid collapses to exactly one frame, and the window expires
    // during the console's 10 ms drain so the next command always goes out.
    //
    // READS ARE NEVER SUPPRESSED. The far memory can change between two
    // identical reads - another master on their side, or their own console -
    // so answering a repeat from a remembered value would hand back stale
    // data. remote_link_tb catches exactly that: it reads a far location,
    // the far side changes it, and reads again expecting the new value.
    // ------------------------------------------------------------------
    localparam DUPW = $clog2(DUP_WINDOW+1);

    logic [23:0]     new_cmd, last_cmd;
    logic            dup_valid, is_dup;
    logic [DUPW-1:0] dup_tmr;

    assign new_cmd = sp_memwen ? {sp_memwdata, bdev, sp_memaddr, 1'b1, 1'b0}
                               : {{DATA_WIDTH{1'b0}}, bdev, sp_memaddr, 1'b0, 1'b0};
    assign is_dup  = dup_valid && (new_cmd == last_cmd) && sp_memwen;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            last_cmd  <= '0;
            dup_valid <= 1'b0;
            dup_tmr   <= '0;
        end else begin
            if (wen_rise || ren_rise) begin      // any request restarts it
                last_cmd  <= new_cmd;
                dup_valid <= 1'b1;
                dup_tmr   <= '0;
            end else if (dup_valid) begin
                if (dup_tmr == DUP_WINDOW[DUPW-1:0]) dup_valid <= 1'b0;
                else                                 dup_tmr   <= dup_tmr + 1'b1;
            end
        end
    end

    // a suppressed duplicate never reaches the transmitter
    assign req_set = (wen_rise | ren_rise) & ~is_dup;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            c_state        <= C_IDLE;
            req_cmd        <= '0;
            tmo            <= '0;
            is_read        <= 1'b0;
            rd_data        <= '0;
            rdata_received <= 1'b0;
            derror         <= 1'b0;
        end else begin
            unique case (c_state)
                C_IDLE: begin
                    tmo            <= '0;
                    rdata_received <= 1'b0;
                    if (wen_rise || ren_rise) begin
                        req_cmd <= new_cmd;
                        is_read <= ren_rise;
                        if (is_dup) begin
                            // a repeat of the same write, still inside the
                            // window. It is already on its way to the far
                            // memory, so absorb it and put nothing on the
                            // wire. A write is posted, nothing is owed back.
                            derror  <= 1'b0;
                            c_state <= C_IDLE;
                        end else begin
                            derror  <= 1'b0;
                            c_state <= C_SEND;
                        end
                    end
                end

                // counting already here, so a jammed transmitter cannot hang us
                C_SEND: begin
                    tmo <= tmo + 1'b1;
                    if (c_timeout) begin
                        rd_data        <= ERR_DATA;
                        rdata_received <= 1'b1;
                        derror         <= 1'b1;
                        c_state        <= is_read ? C_DONE : C_IDLE;
                    end else if (req_ack)
                        c_state <= is_read ? C_WAIT : C_IDLE;
                end

                C_WAIT: begin
                    tmo <= tmo + 1'b1;
                    if (resp_stb) begin
                        rd_data        <= resp_byte;
                        rdata_received <= 1'b1;
                        c_state        <= C_DONE;
                    end else if (c_timeout) begin
                        rd_data        <= ERR_DATA;
                        rdata_received <= 1'b1;
                        derror         <= 1'b1;
                        c_state        <= C_DONE;
                    end
                end

                // hold the answer until the slave port has shifted it all out
                C_DONE: if (!sp_memren) begin
                    rdata_received <= 1'b0;
                    c_state        <= C_IDLE;
                end

                default: c_state <= C_IDLE;
            endcase
        end
    end

    assign dbg_busy = (c_state != C_IDLE);

    // rm_rx is asynchronous, so sync it before looking for a low level
    logic rxl_meta, rxl_sync;
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) {rxl_sync, rxl_meta} <= 2'b11;
        else       {rxl_sync, rxl_meta} <= {rxl_meta, u_rx};
    end

    assign dbg_rx_level = rxl_sync;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dbg_rx_any    <= 1'b0;
            dbg_resp_seen <= 1'b0;
            dbg_req_sent  <= 1'b0;
            dbg_tx_ran    <= 1'b0;
            dbg_rx_low    <= 1'b0;
        end else if (req_set) begin
            dbg_rx_any    <= 1'b0;
            dbg_resp_seen <= 1'b0;
            dbg_req_sent  <= 1'b0;
            dbg_tx_ran    <= 1'b0;
            dbg_rx_low    <= 1'b0;
        end else begin
            if (rx_stb)     dbg_rx_any    <= 1'b1;
            if (resp_stb)   dbg_resp_seen <= 1'b1;
            if (req_ack)    dbg_req_sent  <= 1'b1;
            if (u_tx_busy)  dbg_tx_ran    <= 1'b1;
            if (!rxl_sync)  dbg_rx_low    <= 1'b1;
        end
    end

    // split control: keep the local master parked, and the bus free, until the
    // far side actually answered. same trick bus_bridge_slave uses.
    logic read_in_progress;
    assign read_in_progress = is_read && (c_state != C_IDLE);

    assign sp_split_grant = read_in_progress ? (split_grant && rdata_received) : split_grant;
    assign ssplit         = sp_ssplit || (read_in_progress && !rdata_received);

    assign sp_memrdata = read_in_progress ? rd_data : '0;
    assign sp_rvalid   = read_in_progress ? rdata_received : 1'b0;

    // busy to the decoder until the frame is away and the answer delivered
    assign sready = sp_ready && !sp_memwen && !sp_memren && (c_state == C_IDLE);

    // ------------------------------------------------------------------
    // server: link request -> our bus -> answer
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_ISSUE, S_EXEC0, S_EXEC1, S_RESP} s_state_t;
    s_state_t s_state;

    logic [RADDR_W-1:0]    srv_addr;
    logic [DATA_WIDTH-1:0] srv_wdata;
    logic                  srv_mode;

    assign mp_dvalid = (s_state == S_ISSUE) && mp_dready;
    assign mp_daddr  = {{(ADDR_WIDTH-RADDR_W){1'b0}}, srv_addr};
    assign mp_dwdata = srv_wdata;
    assign mp_dmode  = srv_mode;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_state   <= S_IDLE;
            srv_addr  <= '0;
            srv_wdata <= '0;
            srv_mode  <= 1'b0;
            resp_data <= '0;
        end else begin
            unique case (s_state)
                S_IDLE: begin
                    if (req_stb) begin              // latch and hold
                        srv_wdata <= rx_cmd[23:16];
                        srv_addr  <= rx_cmd[15:2];
                        srv_mode  <= rx_cmd[1];     // rx_cmd[0] reserved, ignored
                        s_state   <= S_ISSUE;
                    end
                end

                S_ISSUE: if (mp_dready) s_state <= S_EXEC0;

                S_EXEC0: s_state <= S_EXEC1;        // engine took it, dready is low now

                S_EXEC1: if (mp_dready) begin
                    resp_data <= mp_drdata;
                    s_state   <= srv_mode ? S_IDLE : S_RESP;   // posted write, no answer
                end

                S_RESP: if (!resp_pend) s_state <= S_IDLE;

                default: s_state <= S_IDLE;
            endcase
        end
    end

    assign resp_set = (s_state == S_RESP) && !resp_pend;

endmodule
