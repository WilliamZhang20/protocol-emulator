`default_nettype none
// Prototype mesh for the compiler (FABRIC_REORG.md, promotion criterion 3,
// step 4 L0, and the grid-size study): ROWS x COLS cells, each a coarse
// tile beside a contexted switch (ctx_switch), configured from one flat
// vector the compiler emits. The interconnect (ctx_switch, the mesh, the
// word network) is fixed; cell kinds, context counts and the word-port
// cell are parameters. A mesh contract (written by the compiler's
// fabric_arch.py) holds the same values and is the only description the
// compiler reads. The default is the 3 x 3 prototype:
//
//   0 io      1 io      2 shifter
//   3 timer   4 crc     5 shifter        (4: word port)
//   6 io      7 shifter 8 timer
//
// KINDS: 2 bits per cell (0 io, 1 timer, 2 shifter, 3 crc). CTX4: 1 bit
// per cell, 4 contexts if set, else 1 (transition rows tied off).
// Cell kinds, local outputs (k) and sinks (k):
//   io      locals: the io_tile's 4 outputs
//           sinks: 0 pad A value 1 pad A enable 2 pad B value 3 pad B enable
//   timer   locals: 0 tick 1 level 2 rise 3 fall   sinks: 0 start 1 stop 2 aux
//   shifter locals: 0 word 1 stop 2 out 3 active
//           sinks: 0 start 1 shift 2 sample 3 abort 4 in
//           lines: 1 start, 2 shift, 3 abort, 4 sample; level 33 in
//   crc     locals: 0 ok, and at the word port 1 reader data available,
//           2 compare-tap match, 3 mismatch
//           sinks: 0 init 1 absorb 2 emit 3 data 4 level (gate) 5 word gate
//           lines: 1 init, 2 absorb, 3 emit; levels 33 data, 34 level.
//           Its direct link (fabric_crc's shifter link) reaches the shifter
//           to its west (link 0) and to its east (link 1).
// Configuration (CELL_BITS per cell, then the word network):
//   [0,192) track_cfg, [192,312) sink_cfg (6 sinks), [312,368) trans_cfg,
//   [368,512) tile:
//     io {pad B [51:46], pad A [45:40], outputs [39:0]}, a pad field
//       {invert[5], push-pull[4], pad[3:1], used[0]};
//     timer {phase[63:48], mode[47:32], period[31:16], first[15:0]};
//     shifter registers 1..6 at [16(r-1) +: 16];
//     crc registers 0..7 at [16r +: 16].
//   Word network at WNET_LSB: sel[31:0], escape m0,m1,byte,r0,r1 [71:32],
//   compare value [87:72], mask [103:88], split msb [104], tap [108:105],
//   rx cell [112:109], tx cell [116:113] (the shifters whose receive FIFO
//   feeds the network and whose transmit FIFO it feeds; 15: none).
// Pads: open drain (enable and value 0 pull low) or push-pull (enable
// drives value); invert applies to the value.
module mesh #(parameter ROWS=3, COLS=3, WORD_PORT=4,
  parameter [2*ROWS*COLS-1:0] KINDS=18'b01_10_00_10_11_01_10_00_00,
  parameter [ROWS*COLS-1:0] CTX4=9'b011110111,
  parameter CELL_BITS=512, WNET_BITS=128,
  parameter CFG_BITS=ROWS*COLS*CELL_BITS+WNET_BITS)(
  input wire clk, rst_n, run_req,
  input wire [CFG_BITS-1:0] cfg,
  input wire [7:0] pins,                 // pad levels, from the bench
  output reg [7:0] pad_oe, output reg [7:0] pad_out,
  output wire ready,                     // configuration written; run follows run_req
  input wire [15:0] rd_data, input wire rd_valid, output wire rd_ready,   // reader (SRAM side)
  output wire [15:0] wr_data, output wire wr_valid, input wire wr_ready,  // writer
  output wire [ROWS*COLS-1:0] host_valid, // receive bytes of shifters outside the word network
  output wire [8*ROWS*COLS-1:0] host_byte);
  localparam N=ROWS*COLS, TRACK_LSB=0, SINK_LSB=192, TRANS_LSB=312, TILE_LSB=368;
  localparam WNET_LSB=N*CELL_BITS;
  localparam IO=0, TIMER=1, SHIFTER=2, CRC=3;
  function integer kind(input integer c); kind = KINDS[2*c+:2]; endfunction
  function integer contexts(input integer c); contexts = CTX4[c] ? 4 : 1; endfunction

  // Configuration load: shifter registers 1..6 and CRC registers 0..7
  // written over eight clocks.
  reg [2:0] load; reg loaded;
  always @(posedge clk)
    if(!rst_n) begin load<=0; loaded<=0; end
    else if(!loaded) begin if(load==7) loaded<=1; load<=load+1; end
  assign ready=loaded;
  wire run=run_req && loaded;

  wire [3:0] n_out[0:N-1], s_out[0:N-1], w_out[0:N-1], e_out[0:N-1], local_out[0:N-1];
  wire [5:0] sinks[0:N-1];
  wire [7:0] oe[0:N-1], ov[0:N-1];
  // Shifter FIFO ports, CRC links and the word network's bit pins.
  wire [7:0] rx_byte[0:N-1]; wire [N-1:0] rx_req, rx_grant, tx_req, tx_grant;
  wire [N-1:0] l_absorb, l_bit, l_emit, tail;
  wire [WNET_BITS-1:0] wc=cfg[WNET_LSB+:WNET_BITS];
  wire [3:0] rx_cell=wc[112:109], tx_cell=wc[116:113];
  wire tap_match, tap_mismatch, wn_rx_ready, wn_txv; wire [15:0] wn_tx;

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
      // Pad A from sinks 0/1, pad B from sinks 2/3.
      wire [5:0] fa=tile[45:40], fb=tile[51:46];
      wire va=sinks[c][0]^fa[5], vb=sinks[c][2]^fb[5];
      // No pad is driven until the fabric runs.
      wire ea=run && fa[0] && sinks[c][1] && (fa[4] || !va), eb=run && fb[0] && sinks[c][3] && (fb[4] || !vb);
      assign oe[c]=(ea ? 8'd1<<fa[3:1] : 8'd0) | (eb ? 8'd1<<fb[3:1] : 8'd0);
      assign ov[c]=(ea && fa[4] && va ? 8'd1<<fa[3:1] : 8'd0) | (eb && fb[4] && vb ? 8'd1<<fb[3:1] : 8'd0);
      assign rx_req[c]=0; assign rx_byte[c]=0; assign tx_req[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0; assign tail[c]=0;
    end else if(kind(c)==TIMER) begin: tm
      wire tick, running, configured, level, rise, fall; wire [15:0] cap;
      grid_timer t(clk,rst_n,run,!loaded,tile[15:0],tile[31:16],1'b0,16'd0,16'd0,tile[47:32],tile[63:48],
        sinks[c][0],sinks[c][1],sinks[c][2],tick,running,configured,level,rise,fall,cap);
      assign local_out[c]={fall,rise,level,tick};
      assign oe[c]=0; assign ov[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0; assign tx_req[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0; assign tail[c]=0;
    end else if(kind(c)==SHIFTER) begin: sh
      wire word, stop, out, active; wire [4:0] nc; wire [15:0] rxd, st;
      wire [63:0] lines={30'b0,sinks[c][4],1'b0,27'b0,sinks[c][2],sinks[c][3],sinks[c][1],sinks[c][0],1'b0}; // 1 start 2 shift 3 abort 4 sample, 33 in
      // The CRC beside it: east (this shifter is its link 0) or west (link 1).
      wire crc_in = (COL<COLS-1 && kind(NB_E)==CRC) ? tail[NB_E] : (COL>0 && kind(NB_W)==CRC) ? tail[NB_W] : 1'b0;
      wire [2:0] sh_addr=load+3'd1;
      fabric_shifter t(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we(!loaded && load<6),.cfg_addr(sh_addr),
        .cfg_data(tile[16*load+:16]),.cfg_bank(2'b11),.ctx_next(1'b0),.lines(lines),.pulls(nc[0]),
        .tx_request(tx_req[c]),.tx_grant(tx_grant[c]),.tx_data(wn_tx[7:0]),.tx_eop(1'b0),.tx_err(1'b0),
        .rx_request(rx_req[c]),.rx_grant(rx_grant[c]),.crc_in(crc_in),.rx_byte(rx_byte[c]),.rx_eop(nc[1]),
        .rx_err(nc[2]),.out(out),.active(active),.word_pulse(word),.stop_pulse(stop),.rx_data(rxd),
        .status(st),.crc_absorb(l_absorb[c]),.crc_bit(l_bit[c]),.crc_emit(l_emit[c]));
      assign local_out[c]={active,out,stop,word};
      assign oe[c]=0; assign ov[c]=0; assign tail[c]=0;
    end else begin: cr
      wire ok, out, tl; wire [31:0] value;
      wire [63:0] lines={29'b0,sinks[c][4],sinks[c][3],1'b0,28'b0,sinks[c][2],sinks[c][1],sinks[c][0],1'b0}; // 1 init 2 absorb 3 emit, 33 data 34 level
      wire [1:0] la={(COL<COLS-1 && kind(NB_E)==SHIFTER) ? l_absorb[NB_E] : 1'b0, (COL>0 && kind(NB_W)==SHIFTER) ? l_absorb[NB_W] : 1'b0};
      wire [1:0] lb={(COL<COLS-1 && kind(NB_E)==SHIFTER) ? l_bit[NB_E] : 1'b0, (COL>0 && kind(NB_W)==SHIFTER) ? l_bit[NB_W] : 1'b0};
      wire [1:0] le={(COL<COLS-1 && kind(NB_E)==SHIFTER) ? l_emit[NB_E] : 1'b0, (COL>0 && kind(NB_W)==SHIFTER) ? l_emit[NB_W] : 1'b0};
      fabric_crc t(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we(!loaded),.cfg_addr(load),.cfg_data(tile[16*load+:16]),
        .lines(lines),.link_absorb(la),.link_bit(lb),.link_emit(le),.out(out),.tail_out(tl),.ok(ok),.value(value));
      assign tail[c]=tl;
      assign local_out[c]= c==WORD_PORT ? {tap_mismatch,tap_match,rd_valid,ok} : {3'b0,ok};
      assign oe[c]=0; assign ov[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0; assign tx_req[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0;
    end
    // A shifter's FIFOs connect to the word network if it is the
    // configured rx / tx cell; a receive FIFO otherwise feeds the host.
    assign rx_grant[c]= rx_cell==c ? rx_req[c] && wn_rx_ready : rx_req[c];
    assign tx_grant[c]= tx_cell==c && tx_req[c] && wn_txv;
    assign host_valid[c]= rx_cell!=c && rx_req[c];
    assign host_byte[8*c+:8]=rx_byte[c];
  end endgenerate

  integer p;
  always @* begin
    pad_oe=0; pad_out=0;
    for(p=0;p<N;p=p+1) begin pad_oe=pad_oe|oe[p]; pad_out=pad_out|ov[p]; end
  end

  wire [7:0] wrx=rx_byte[rx_cell<N ? rx_cell : 0];
  wire wrx_v= rx_cell<N && rx_req[rx_cell<N ? rx_cell : 0];
  wire wtx_r= tx_cell<N && tx_req[tx_cell<N ? tx_cell : 0];
  wire wn_match, wn_ok; wire wn_st, wn_cap;
  wnet words(clk,rst_n,wc[31:0],wc[39:32],wc[47:40],wc[55:48],wc[63:56],wc[71:64],wc[87:72],wc[103:88],
    sinks[WORD_PORT][5],wn_match,wc[104],wc[108:105],tap_match,tap_mismatch,
    rd_data,rd_valid,rd_ready, {8'd0,wrx},wrx_v,wn_rx_ready, 16'd0,1'b0,wn_st, 16'd0,1'b0,wn_cap,
    wr_data,wr_valid,wr_ready, wn_tx,wn_txv,wtx_r, wn_ok);
endmodule
`default_nettype wire
