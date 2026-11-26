`default_nettype none
// Prototype mesh for the compiler (FABRIC_REORG.md, promotion criterion 3,
// and the grid-size study): ROWS x COLS cells, each a coarse tile beside a
// contexted switch (ctx_switch), configured from one flat vector the
// compiler emits. The cell kinds, context counts and word-port cell are
// parameters; a mesh contract (mesh_*.json, written by the compiler's
// fabric_arch.py) holds the same values and is the only description the
// compiler reads. The default is the 3 x 3 prototype:
//
//   0 io      1 io      2 shifter (+ word port)
//   3 timer   4 timer   5 shifter
//   6 io      7 shifter 8 timer
//
// KINDS: 2 bits per cell (0 io, 1 timer, 2 shifter). CTX4: 1 bit per cell,
// 4 contexts if set, else 1 (the transition rows are tied off, so the
// switch stays in context 0).
// Cell kinds, local outputs (k) and sinks (k):
//   io      locals: the io_tile's 4 outputs   sinks: 0 drive value, 1 drive enable
//   timer   locals: 0 tick 1 level 2 rise 3 fall   sinks: 0 start 1 stop 2 aux
//   shifter locals: 0 word 1 stop 2 match 3 mismatch (word port cell only)
//           sinks: 0 start 1 shift 2 sample 3 abort 4 in 5 gate (word port only)
//           lines: 1 start, 2 shift, 3 abort, 4 sample; level 33 in
// Configuration (CELL_BITS per cell, then the word network):
//   [0,192) track_cfg, [192,312) sink_cfg (6 sinks), [312,368) trans_cfg,
//   [368,512) tile: io {drive used[43], drive pin[42:40], outputs[39:0]};
//   timer {phase[63:48], mode[47:32], period[31:16], first[15:0]};
//   shifter registers 1..6 at [16(r-1) +: 16].
//   Word network at WNET_LSB: sel[31:0], escape m0,m1,byte,r0,r1 [71:32],
//   compare value [87:72], mask [103:88], split msb [104], tap [108:105],
//   rx cell [112:109] (the shifter whose receive FIFO feeds the network).
// Pins are open drain: an io cell with its driver used pulls its pin low
// while drive enable is high and drive value low.
module mesh #(parameter ROWS=3, COLS=3, WORD_PORT=2,
  parameter [2*ROWS*COLS-1:0] KINDS=18'b01_10_00_10_01_01_10_00_00,
  parameter [ROWS*COLS-1:0] CTX4=9'b011100111,
  parameter CELL_BITS=512, WNET_BITS=128,
  parameter CFG_BITS=ROWS*COLS*CELL_BITS+WNET_BITS)(
  input wire clk, rst_n, run_req,
  input wire [CFG_BITS-1:0] cfg,
  input wire [7:0] pins,                 // pad levels (after the open-drain wiring, from the bench)
  output reg [7:0] pull_low,
  output wire ready,                     // configuration written; run follows run_req
  output wire [15:0] wr_data, output wire wr_valid, input wire wr_ready,
  output wire [ROWS*COLS-1:0] host_valid, // receive bytes of shifters outside the word network
  output wire [8*ROWS*COLS-1:0] host_byte);
  localparam N=ROWS*COLS, TRACK_LSB=0, SINK_LSB=192, TRANS_LSB=312, TILE_LSB=368;
  localparam WNET_LSB=N*CELL_BITS;
  localparam IO=0, TIMER=1, SHIFTER=2;
  function integer kind(input integer c); kind = KINDS[2*c+:2]; endfunction
  function integer contexts(input integer c); contexts = CTX4[c] ? 4 : 1; endfunction

  // Configuration load: shifter registers 1..6 written over six clocks.
  reg [2:0] load; reg loaded;
  always @(posedge clk)
    if(!rst_n) begin load<=0; loaded<=0; end
    else if(!loaded) begin if(load==5) loaded<=1; load<=load+1; end
  assign ready=loaded;
  wire run=run_req && loaded;
  wire [2:0] reg_addr=load+3'd1;

  wire [3:0] n_out[0:N-1], s_out[0:N-1], w_out[0:N-1], e_out[0:N-1], local_out[0:N-1];
  wire [5:0] sinks[0:N-1];
  wire [7:0] pull[0:N-1];
  // Shifter receive ports and the word network's bit pins.
  wire [7:0] rx_byte[0:N-1]; wire [N-1:0] rx_req, rx_grant;
  wire [WNET_BITS-1:0] wc=cfg[WNET_LSB+:WNET_BITS];
  wire [3:0] rx_cell=wc[112:109];
  wire tap_match, tap_mismatch, wn_rx_ready;

  genvar c;
  generate for(c=0;c<N;c=c+1) begin: cl
    localparam ROW=c/COLS, COL=c%COLS;
    wire [CELL_BITS-1:0] cc=cfg[c*CELL_BITS+:CELL_BITS];
    wire [143:0] tile=cc[TILE_LSB+:144];
    localparam NB_N = ROW>0 ? c-COLS : c, NB_S = ROW<ROWS-1 ? c+COLS : c,
               NB_W = COL>0 ? c-1 : c, NB_E = COL<COLS-1 ? c+1 : c;
    wire [3:0] nin = ROW>0 ? s_out[NB_N] : 4'b0;
    wire [3:0] sin = ROW<ROWS-1 ? n_out[NB_S] : 4'b0;
    wire [3:0] win = COL>0 ? e_out[NB_W] : 4'b0;
    wire [3:0] ein = COL<COLS-1 ? w_out[NB_E] : 4'b0;
    wire [55:0] trans = contexts(c)>1 ? cc[TRANS_LSB+:56] : 56'b0;
    wire [1:0] ctx;
    ctx_switch #(.NSINK(6)) sw(clk,run,nin,sin,win,ein,local_out[c],
      cc[TRACK_LSB+:192], cc[SINK_LSB+:120], trans,
      n_out[c],s_out[c],w_out[c],e_out[c], sinks[c], ctx);
    if(kind(c)==IO) begin: io
      wire [3:0] o;
      io_tile t(clk,run,pins,tile[39:0],o);
      assign local_out[c]=o;
      assign pull[c]=(tile[43] && sinks[c][1] && !sinks[c][0]) ? (8'd1<<tile[42:40]) : 8'd0;
      assign rx_req[c]=0; assign rx_byte[c]=0;
    end else if(kind(c)==TIMER) begin: tm
      wire tick, running, configured, level, rise, fall; wire [15:0] cap;
      grid_timer t(clk,rst_n,run,!loaded,tile[15:0],tile[31:16],1'b0,16'd0,16'd0,tile[47:32],tile[63:48],
        sinks[c][0],sinks[c][1],sinks[c][2],tick,running,configured,level,rise,fall,cap);
      assign local_out[c]={fall,rise,level,tick};
      assign pull[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0;
    end else begin: sh
      wire word, stop; wire [8:0] nc; wire [15:0] rxd, st;
      wire [63:0] lines={30'b0,sinks[c][4],1'b0,27'b0,sinks[c][2],sinks[c][3],sinks[c][1],sinks[c][0],1'b0}; // 1 start 2 shift 3 abort 4 sample, 33 in
      fabric_shifter t(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we(!loaded),.cfg_addr(reg_addr),
        .cfg_data(tile[16*load+:16]),.cfg_bank(2'b11),.ctx_next(1'b0),.lines(lines),.pulls(nc[0]),
        .tx_request(nc[1]),.tx_grant(1'b0),.tx_data(8'd0),.tx_eop(1'b0),.tx_err(1'b0),
        .rx_request(rx_req[c]),.rx_grant(rx_grant[c]),.crc_in(1'b0),.rx_byte(rx_byte[c]),.rx_eop(nc[2]),
        .rx_err(nc[3]),.out(nc[4]),.active(nc[5]),.word_pulse(word),.stop_pulse(stop),.rx_data(rxd),
        .status(st),.crc_absorb(nc[6]),.crc_bit(nc[7]),.crc_emit(nc[8]));
      assign local_out[c]= c==WORD_PORT ? {tap_mismatch,tap_match,stop,word} : {2'b0,stop,word};
      assign pull[c]=0;
    end
    // A shifter's receive FIFO feeds the word network if it is the
    // configured rx cell, else the host directly.
    assign rx_grant[c]= rx_cell==c ? rx_req[c] && wn_rx_ready : rx_req[c];
    assign host_valid[c]= rx_cell!=c && rx_req[c];
    assign host_byte[8*c+:8]=rx_byte[c];
  end endgenerate

  integer p;
  always @* begin pull_low=0; for(p=0;p<N;p=p+1) pull_low=pull_low|pull[p]; end

  wire [7:0] wrx=rx_byte[rx_cell<N ? rx_cell : 0];
  wire wrx_v= rx_cell<N && rx_req[rx_cell<N ? rx_cell : 0];
  wire wn_match, wn_ok; wire [15:0] wn_tx; wire wn_txv, wn_rd, wn_st, wn_cap;
  wnet words(clk,rst_n,wc[31:0],wc[39:32],wc[47:40],wc[55:48],wc[63:56],wc[71:64],wc[87:72],wc[103:88],
    sinks[WORD_PORT][5],wn_match,wc[104],wc[108:105],tap_match,tap_mismatch,
    16'd0,1'b0,wn_rd, {8'd0,wrx},wrx_v,wn_rx_ready, 16'd0,1'b0,wn_st, 16'd0,1'b0,wn_cap,
    wr_data,wr_valid,wr_ready, wn_tx,wn_txv,1'b1, wn_ok);
endmodule
`default_nettype wire
