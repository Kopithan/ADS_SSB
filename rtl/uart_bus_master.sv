`timescale 1ns/1ps
//=============================================================================
// uart_bus_master
//
// Master port with a remote-access link bolted on. Wraps ONE master_port (the
// bus transaction engine) and shares it between two roles:
//
//   client - a local command with dremote=1 is not run on our bus at all. It
//            is packed into a REQUEST frame, sent over the UART, executed by
//            the far board, and the answer comes back in a RESPONSE frame.
//   server - a REQUEST arriving on the UART is latched, then run on OUR bus
//            through the same engine, and the result is sent back.
//
// A local command with dremote=0 goes straight through to the engine with the
// same timing as a bare master_port, so local behaviour is unchanged.
//
// Wire protocol (fixed, must match the far board byte for byte):
//   REQUEST   0xA5, b0, b1, b2      b0=cmd[7:0] b1=cmd[15:8] b2=cmd[23:16]
//   RESPONSE  0x5A, data
//   cmd = {wdata[7:0], addr[13:0], we, 1'b0}
//   read  response data = byte read on the far bus
//   write response data = 0x00 (acknowledgement only)
//
// Our bus address is 16 bits, but addr[15:12] is a device id and the decoder
// only honours 0..2, so addr[15:14] is always 00 on any transaction that can
// do anything. Sending addr[13:0] is therefore lossless; we zero-extend on
// receive.
//=============================================================================

module uart_bus_master #(
    parameter ADDR_WIDTH           = 16,
    parameter DATA_WIDTH           = 8,
    parameter SLAVE_MEM_ADDR_WIDTH = 12,
    parameter CLKS_PER_BIT         = 434,     // 50MHz / 115200
    parameter RESP_TIMEOUT         = 500000   // 10ms @ 50MHz
)(
    input  logic clk,
    input  logic rstn,

    // master device side
    input  logic [DATA_WIDTH-1:0] dwdata,
    output logic [DATA_WIDTH-1:0] drdata,
    input  logic [ADDR_WIDTH-1:0] daddr,
    input  logic                  dvalid,
    output logic                  dready,   // = cmd_done, only rises when answered
    input  logic                  dmode,    // = cmd_we, 0 read, 1 write
    input  logic                  dremote,  // = cmd_remote, 0 local, 1 over uart
    output logic                  derror,   // = cmd_error, remote timed out

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

    // remote link
    output logic u_tx,
    input  logic u_rx
);

    localparam [7:0] TAG_REQ  = 8'hA5;
    localparam [7:0] TAG_RESP = 8'h5A;
    localparam       RADDR_W  = 14;          // address bits carried on the wire
    localparam [7:0] ERR_DATA = 8'hFF;       // returned on timeout
    localparam       TMO_W    = $clog2(RESP_TIMEOUT+1);

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH != 8)
            $fatal(1, "uart_bus_master: byte based wire protocol needs DATA_WIDTH=8");
    end
    // synthesis translate_on

    // ------------------------------------------------------------------
    // the one shared transaction engine
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] mp_daddr;
    logic [DATA_WIDTH-1:0] mp_dwdata, mp_drdata;
    logic                  mp_dvalid, mp_dready, mp_dmode;

    master_port #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SLAVE_MEM_ADDR_WIDTH(SLAVE_MEM_ADDR_WIDTH)
    ) engine (
        .clk(clk), .rstn(rstn),
        .dwdata(mp_dwdata), .drdata(mp_drdata), .daddr(mp_daddr),
        .dvalid(mp_dvalid), .dready(mp_dready), .dmode(mp_dmode),
        .mrdata(mrdata), .mwdata(mwdata), .mmode(mmode),
        .mvalid(mvalid), .svalid(svalid),
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

    logic u_rx_ready_q;
    logic rx_stb;
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
    // if both boards fire a remote command at once, each is waiting for a
    // reply while holding one to send; letting requests win deadlocks both.
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
    // command mux: a local command always beats the server, and the server
    // only ever starts when the engine is genuinely free.
    // ------------------------------------------------------------------
    logic local_cmd_now, srv_issue;
    logic [RADDR_W-1:0] srv_addr;
    logic [7:0]         srv_wdata;
    logic               srv_mode;

    typedef enum logic [2:0] {S_IDLE, S_WAIT_ENG, S_EXEC0, S_EXEC1, S_RESP} s_state_t;
    s_state_t s_state;

    assign local_cmd_now = dvalid & ~dremote;

    // free engine, no local command this cycle, previous answer already gone
    assign srv_issue = (s_state == S_WAIT_ENG) & mp_dready & ~local_cmd_now & ~resp_pend;

    assign mp_dvalid = local_cmd_now | srv_issue;
    assign mp_daddr  = srv_issue ? {{(ADDR_WIDTH-RADDR_W){1'b0}}, srv_addr} : daddr;
    assign mp_dwdata = srv_issue ? srv_wdata : dwdata;
    assign mp_dmode  = srv_issue ? srv_mode  : dmode;

    // ------------------------------------------------------------------
    // client: local remote command -> uart -> answer
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {C_IDLE, C_SEND, C_WAIT} c_state_t;
    c_state_t c_state;

    logic [TMO_W-1:0] tmo;
    logic [7:0]       remote_rdata;
    logic             last_remote, derr_reg;
    logic             c_accept, c_busy, c_timeout, c_gotresp;

    assign c_accept  = (c_state == C_IDLE) && dvalid && dremote && mp_dready && !req_pend;
    assign c_busy    = (c_state != C_IDLE);
    assign c_timeout = c_busy && (tmo == RESP_TIMEOUT[TMO_W-1:0]);
    assign c_gotresp = (c_state == C_WAIT) && resp_stb;
    assign req_set   = c_accept;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            c_state <= C_IDLE;
            req_cmd <= '0;
            tmo     <= '0;
        end else begin
            unique case (c_state)
                C_IDLE: begin
                    tmo <= '0;
                    if (c_accept) begin
                        req_cmd <= {dwdata, daddr[RADDR_W-1:0], dmode, 1'b0};
                        c_state <= C_SEND;
                    end
                end

                // counting already here, so a jammed transmitter cannot hang us
                C_SEND: begin
                    tmo <= tmo + 1'b1;
                    if      (c_timeout) c_state <= C_IDLE;
                    else if (req_ack)   c_state <= C_WAIT;
                end

                C_WAIT: begin
                    tmo <= tmo + 1'b1;
                    if (c_gotresp || c_timeout) c_state <= C_IDLE;
                end

                default: c_state <= C_IDLE;
            endcase
        end
    end

    // result selection + sticky error, both settle before dready rises
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            remote_rdata <= '0;
            last_remote  <= 1'b0;
            derr_reg     <= 1'b0;
        end else begin
            if (local_cmd_now && mp_dready) begin
                last_remote <= 1'b0;      // local result comes from the engine
                derr_reg    <= 1'b0;
            end else if (c_accept) begin
                derr_reg    <= 1'b0;      // new remote command clears stale error
            end else if (c_gotresp) begin
                remote_rdata <= resp_byte;
                last_remote  <= 1'b1;
                derr_reg     <= 1'b0;
            end else if (c_timeout) begin
                remote_rdata <= ERR_DATA;
                last_remote  <= 1'b1;
                derr_reg     <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // server: uart request -> our bus -> answer
    // ------------------------------------------------------------------
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
                        s_state   <= S_WAIT_ENG;
                    end
                end

                S_WAIT_ENG: if (srv_issue) s_state <= S_EXEC0;

                S_EXEC0: s_state <= S_EXEC1;        // engine took it, dready is low now

                S_EXEC1: if (mp_dready) begin
                    resp_data <= srv_mode ? 8'h00 : mp_drdata;   // write = bare ack
                    s_state   <= S_RESP;
                end

                S_RESP: if (!resp_pend) s_state <= S_IDLE;

                default: s_state <= S_IDLE;
            endcase
        end
    end

    assign resp_set = (s_state == S_RESP) && !resp_pend;

    // ------------------------------------------------------------------
    // device side outputs
    // ------------------------------------------------------------------
    assign dready = (c_state == C_IDLE) ? mp_dready : 1'b0;
    assign drdata = last_remote ? remote_rdata : mp_drdata;
    assign derror = derr_reg;

endmodule
