`default_nettype none
// Prototype mesh for the compiler (FABRIC_REORG.md, promotion criterion 3,
// step 4 L0, and the grid-size study): ROWS x COLS cells, each a coarse
// tile beside a contexted switch (ctx_switch), configured from one flat
// vector the compiler emits. The interconnect (ctx_switch, the mesh, the
// word network) is fixed; cell kinds, context counts and the word-port
// cell are parameters. A mesh contract (written by the compiler's
// fabric_arch.py) holds the same values and is the only description the
// compiler reads. The defaults are the test configuration, a 3 x 5
// candidate (3 rows, 5 columns: wide, like the 8 x 4 Tiny Tapeout die).
// It is not the chosen fabric; the grid-size study decides size and mix:
//
//    0 timer   1 io      2 timer   3 io      4 timer
//    5 shifter 6 crc*    7 shifter 8 crc     9 shifter   (* word port)
//   10 timer  11 io     12 timer  13 io     14 timer
//
// (An earlier arrangement with the io cells in the corners could not
// route the I2C target's muxes: see FABRIC_REORG.md, grid-size study.)
// Contexts on the io and crc cells.
// KINDS: 2 bits per cell (0 io, 1 timer, 2 shifter, 3 crc). CNT: 1 bit per
// cell, a counter cell (its KINDS bits are ignored). CTX4: 1 bit per cell,
// 4 contexts if set, else 1 (transition rows tied off).
// Cell kinds, local outputs (k) and sinks (k):
//   io      locals: the io_tile's 4 outputs
//           sinks: 0 pad A value 1 pad A enable 2 pad B value 3 pad B enable
//   timer   locals: 0 tick 1 level 2 rise 3 fall   sinks: 0 start 1 stop 2 aux
//   shifter locals: 0 word 1 stop 2 out 3 active
//           sinks: 0 start 1 shift 2 sample 3 abort 4 in 5 end
//           lines: 1 start, 2 shift, 3 abort, 4 sample; levels 33 in,
//           34 end (the burst-end level, fabric_shifter register 4)
//   crc     locals: 0 ok, and at the word port 1 reader data available,
//           2 compare-tap match, 3 mismatch
//           sinks: 0 init 1 absorb 2 emit 3 data 4 level (gate) 5 word gate
//           lines: 1 init, 2 absorb, 3 emit; levels 33 data, 34 level.
//           Its direct link (fabric_crc's shifter link) reaches the shifter
//           to its west (link 0) and to its east (link 1).
//           Outside the word port it outputs its serial bit `out`
//           at local 1 (the inverted top register bit: a register); at the
//           word port when bit 10 of its shape word (register 6) is set.
//   counter (fabric_counter) locals: 0 at_least (ge) 1 reached (hit)
//           sinks: 0 step 1 data level 2 clear
//           lines: 1 step, 2 clear; level 33 data.
//   logic   (mesh_logic, LOGIC: 1 bit per cell, its KINDS/CNT/CTX4 bits
//           ignored: one context, so the switch reads context 0 only)
//           locals: 0-3 the LUT registers q0-q3 (q4-q7 stay in the tile)
//           sinks: 0-5 inputs s0-s5 of the eight LUTs
//           Eight 4-input LUTs, each with an output register (the source's
//           `reg`: q loads f when its enable is high, holds its start value
//           while the fabric is stopped), and four host flags h0-h3 (a
//           parameter write while running sets the flags in data[7:4] to
//           data[3:0], the others keep their value; cleared while stopped).
//           An input selects 0-5 sink, 6-13 q0-q7, 14-17 h0-h3, 18
//           constant 0, 19 constant 1 (20-31: 0).
// Host side (FABRIC_REORG.md step 4 L3: a host-sequenced step only before,
// between or at quiescent points of a transaction, never in a wire-timed
// loop):
//   host_ev    one-clock events, read by io outputs in mode 3;
//   seen       a sticky flag per cell local output (4 per cell), cleared
//              by seen_clear, for the host's waits;
//   param_*    a tile-local register write while the fabric runs: counter
//              registers 0..2 (the limit is register 0), shifter registers
//              1..6 (the frame is register 1) and 7 (a loaded value: the
//              byte the shifter sends when its transaction starts, if the word
//              network does not feed it). The compiler only emits one while
//              the tile is idle.
// Configuration (CELL_BITS per cell, then the word network):
//   [0,192) track_cfg, [192,312) sink_cfg (6 sinks), [312,368) trans_cfg,
//   [368,512) tile:
//     io {pad B [51:46], pad A [45:40], outputs [39:0]}, a pad field
//       {invert[5], push-pull[4], pad[3:1], used[0]};
//     timer {phase[63:48], mode[47:32], period[31:16], first[15:0]};
//     shifter registers 1..6 at [16(r-1) +: 16];
//     crc registers 0..7 at [16r +: 16];
//     counter registers 0..2 at [16r +: 16] (0 limit [7:0]; 1 step
//       {mode[12:11], data level[10:6], step line[5:0]}; 2 clear line[4:0]);
//     logic: the tile field and the bits a one-context cell does not
//       read are one 344-bit field L = {transitions [312,368), tracks of
//       contexts 1-3 [48,192), tile [368,512)} (L[143:0] the tile field);
//       LUT k at L[40k +: 40]: truth[15:0] (index {in3,in2,in1,in0}), in i
//       select [16+5i +: 5], enable [38:36] (0 every clock, 1-6 sink 0-5,
//       7 never), start value [39].
//   Word network at WNET_LSB: sel[31:0], escape m0,m1,byte,r0,r1 [71:32],
//   compare value [87:72], mask [103:88], split msb [104], tap [108:105],
//   rx cell [112:109], tx cell [116:113] (the shifters whose receive FIFO
//   feeds the network and whose transmit FIFO it feeds; 15: none).
// REG (registered-routing study, FABRIC_REORG.md step 5; 1 is the mesh):
//   0 combinational tile outputs (admits combinational loops through tiles);
//   1 boundary (the decision): the combinational tile outputs (shifter word
//     and stop, counter reached) are registered where they leave the tile,
//     so every local output is a register and no configuration of any
//     context closes a combinational loop (proved on the netlist with the
//     configuration free: no strongly connected component);
//   2 sinks: every sink is registered where it enters its tile;
//   3 per hop: every switch output to a neighbour is registered.
// Pads: open drain (enable and value 0 pull low) or push-pull (enable
// drives value); invert applies to the value.
module mesh #(parameter ROWS=3, COLS=5, WORD_PORT=6,
  parameter [2*ROWS*COLS-1:0] KINDS=30'd287029521,
  parameter [ROWS*COLS-1:0] CTX4=15'd10570,
  parameter [ROWS*COLS-1:0] CNT=0,
  parameter [ROWS*COLS-1:0] LOGIC=0,
  parameter DSLOTS=0,      // ctx_switch static/dynamic split (0: every selector per context)
  parameter [3:0] CTX_TRACKS=4'b1111, // with DSLOTS=0: tracks held per context (the fixed split)
  parameter REG=1,
  parameter ACTOR=0,       // 1: logic cells also offer the control-actor mode (ACTOR_FABRIC.md A2)
  parameter CELL_BITS=512, WNET_BITS=128,
  parameter CFG_BITS=ROWS*COLS*CELL_BITS+WNET_BITS)(
  input wire clk, rst_n, run_req,
  input wire [3:0] host_ev,
  output wire [4*ROWS*COLS-1:0] seen, input wire seen_clear,
  input wire param_we, input wire [3:0] param_cell, input wire [2:0] param_addr, input wire [15:0] param_data,
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
  localparam IO=0, TIMER=1, SHIFTER=2, CRC=3, COUNTER=4, LOGIC_K=5;
  function integer kind(input integer c); kind = LOGIC[c] ? LOGIC_K : CNT[c] ? COUNTER : {30'd0, KINDS[2*c+:2]}; endfunction
  function integer contexts(input integer c); contexts = CTX4[c] && !LOGIC[c] ? 4 : 1; endfunction

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
  wire [7:0] rx_byte[0:N-1]; wire [N-1:0] rx_req, rx_grant, tx_req, tx_grant, held_grant;
  // A received byte's FIFO tags (fabric_shifter rx_eop / rx_err): the word
  // network carries them in bits 8 (eop) and 9 (err) to the writer.
  wire [N-1:0] rx_eop, rx_err;
  wire [N-1:0] l_absorb, l_bit, l_emit, tail, cok;
  // Each CRC cell's link {select, linked} (its shape register, crc register 6
  // bits [7:6]): linked 1, select 0 west / 1 east.
  wire [1:0] crc_link[0:N-1];
  wire [WNET_BITS-1:0] wc=cfg[WNET_LSB+:WNET_BITS];
  wire [3:0] rx_cell=wc[112:109], tx_cell=wc[116:113];
  wire tap_match, tap_mismatch, wn_rx_ready, wn_txv; wire [15:0] wn_tx;

  genvar c;
  generate for(c=0;c<N;c=c+1) begin: cl
    localparam ROW=c/COLS, COL=c%COLS;
    localparam CELL_LSB=c*CELL_BITS;
    wire [CELL_BITS-1:0] cc=cfg[CELL_LSB+:CELL_BITS];
    wire [143:0] tile=cc[TILE_LSB+:144];
    // The tile's registers as words, chosen by the load counter (an array
    // index, not a run-time part-select base).
    wire [15:0] tw[0:7];
    genvar w;
    for(w=0;w<8;w=w+1) begin: tws
      assign tw[w]=tile[16*w+:16];
    end
    assign crc_link[c]=tile[16*6+6+:2];
    localparam NB_N = ROW>0 ? c-COLS : c, NB_S = ROW<ROWS-1 ? c+COLS : c,
               NB_W = COL>0 ? c-1 : c, NB_E = COL<COLS-1 ? c+1 : c;
    wire [3:0] nin = ROW>0 ? s_out[NB_N] : 4'b0;
    wire [3:0] sin = ROW<ROWS-1 ? n_out[NB_S] : 4'b0;
    wire [3:0] win = COL>0 ? e_out[NB_W] : 4'b0;
    wire [3:0] ein = COL<COLS-1 ? w_out[NB_E] : 4'b0;
    wire [55:0] trans = contexts(c)>1 ? cc[TRANS_LSB+:56] : 56'b0;
    wire [1:0] ctx;
    wire [3:0] no,so,wo,eo; wire [5:0] sk; wire [1:0] xk;
    if(ACTOR && kind(c)==LOGIC_K) begin: sw8
      // An actor-capable logic cell has eight sinks; sinks 6-7 sit where
      // context 1's sinks 0-1 would be (one context: those bits are free).
      wire [7:0] s8;
      ctx_switch #(.NSINK(8), .DSLOTS(0), .CTX_TRACKS(CTX_TRACKS)) sw(clk,run,nin,sin,win,ein,local_out[c],
        cc[TRACK_LSB+:192], {40'b0,cc[SINK_LSB+:120]}, trans,
        no,so,wo,eo, s8, ctx);
      assign sk=s8[5:0]; assign xk=s8[7:6];
    end else begin: sw6
      ctx_switch #(.NSINK(6), .DSLOTS(contexts(c)>1 ? DSLOTS : 0), .CTX_TRACKS(CTX_TRACKS)) sw(clk,run,nin,sin,win,ein,local_out[c],
        cc[TRACK_LSB+:192], cc[SINK_LSB+:120], trans,
        no,so,wo,eo, sk, ctx);
      assign xk=2'b0;
    end
    // Study points (REG): registered sinks or registered hops.
    reg [5:0] sk_r; reg [15:0] hop_r;
    always @(posedge clk) if(!rst_n) begin sk_r<=0; hop_r<=0; end else begin sk_r<=sk; hop_r<={no,so,wo,eo}; end
    assign sinks[c] = REG==2 ? sk_r : sk;
    assign {n_out[c],s_out[c],w_out[c],e_out[c]} = REG==3 ? hop_r : {no,so,wo,eo};
    wire [3:0] lraw;
    // REG 1: the combinational locals leave the tile through a register.
    localparam [3:0] LMASK = REG!=1 ? 4'b0 : kind(c)==SHIFTER ? 4'b0011 : kind(c)==COUNTER ? 4'b0010 : 4'b0;
    reg [3:0] l_r;
    always @(posedge clk) if(!rst_n) l_r<=0; else l_r<=lraw;
    assign local_out[c] = (lraw & ~LMASK) | (l_r & LMASK);
    if(kind(c)==IO) begin: io
      wire [3:0] o;
      io_tile t(clk,run,pins,tile[39:0],o,host_ev);
      assign lraw=o;
      // Pad A from sinks 0/1, pad B from sinks 2/3.
      wire [5:0] fa=tile[45:40], fb=tile[51:46];
      wire va=sinks[c][0]^fa[5], vb=sinks[c][2]^fb[5];
      // No pad is driven until the fabric runs.
      wire ea=run && fa[0] && sinks[c][1] && (fa[4] || !va), eb=run && fb[0] && sinks[c][3] && (fb[4] || !vb);
      assign oe[c]=(ea ? 8'd1<<fa[3:1] : 8'd0) | (eb ? 8'd1<<fb[3:1] : 8'd0);
      assign ov[c]=(ea && fa[4] && va ? 8'd1<<fa[3:1] : 8'd0) | (eb && fb[4] && vb ? 8'd1<<fb[3:1] : 8'd0);
      assign rx_req[c]=0; assign rx_byte[c]=0; assign rx_eop[c]=0; assign rx_err[c]=0; assign tx_req[c]=0; assign held_grant[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0; assign tail[c]=0; assign cok[c]=0;
    end else if(kind(c)==TIMER) begin: tm
      wire tick, running, configured, level, rise, fall; wire [15:0] cap;
      // A host write of register 0 while running is the counter's limit
      // (the counter function, mode bit 2 = tile[34]; ACTOR_FABRIC.md A3).
      wire lw=loaded && param_we && param_cell==c && param_addr==3'd0;
      grid_timer t(clk,rst_n,run,!loaded,tile[15:0],tile[31:16],lw,param_data,16'd1,tile[47:32],tile[63:48],
        sinks[c][0],sinks[c][1],sinks[c][2],tick,running,configured,level,rise,fall,cap);
      // As a counter its locals are fabric_counter's: at_least (level), reached (tick).
      assign lraw= tile[34] ? {2'b0,tick,level} : {fall,rise,level,tick};
      assign oe[c]=0; assign ov[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0; assign rx_eop[c]=0; assign rx_err[c]=0; assign tx_req[c]=0; assign held_grant[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0; assign tail[c]=0; assign cok[c]=0;
    end else if(kind(c)==SHIFTER) begin: sh
      wire word, stop, out, active; wire [2:0] nc; wire [15:0] rxd, st;
      wire [63:0] lines={29'b0,sinks[c][5],sinks[c][4],1'b0,27'b0,sinks[c][2],sinks[c][3],sinks[c][1],sinks[c][0],1'b0}; // 1 start 2 shift 3 abort 4 sample, 33 in, 34 end (burst-end level)
      // The CRC linked to it: the one east of it with link 0 (west), or the
      // one west of it with link 1 (east); a shifter between two CRCs
      // takes the tail only from the one whose link register names it.
      wire crc_in = (COL<COLS-1 && kind(NB_E)==CRC && crc_link[NB_E]==2'b01) ? tail[NB_E] :
                    (COL>0 && kind(NB_W)==CRC && crc_link[NB_W]==2'b11) ? tail[NB_W] : 1'b0;
      wire crc_ok = (COL<COLS-1 && kind(NB_E)==CRC && crc_link[NB_E]==2'b01) ? cok[NB_E] :
                    (COL>0 && kind(NB_W)==CRC && crc_link[NB_W]==2'b11) ? cok[NB_W] : 1'b1;
      wire [2:0] sh_addr=load+3'd1;
      // A host write (param port, registers 1-6) while the tile is idle:
      // the compiler emits one only before a call's transaction.
      wire pw=param_we && param_cell==c;
      // A loaded value (parameter register 7, the shifter idle): a one-byte
      // holding register the shifter takes when its transaction starts, for a
      // shifter the word network does not feed.
      reg [7:0] held; reg full;
      always @(posedge clk)
        if(!rst_n || !run) full<=0;
        else if(loaded && pw && param_addr==3'd7) begin held<=param_data[7:0]; full<=1; end
        else if(held_grant[c]) full<=0;
      assign held_grant[c]= tx_cell!=c && tx_req[c] && full;
      fabric_shifter t(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we((!loaded && load<6) || (loaded && pw)),
        .cfg_addr(loaded ? param_addr : sh_addr),.cfg_data(loaded ? param_data : tw[load]),.cfg_bank(2'b11),.ctx_next(1'b0),.lines(lines),.pulls(nc[0]),
        .tx_request(tx_req[c]),.tx_grant(tx_grant[c]),.tx_data(tx_cell==c ? wn_tx[7:0] : held),.tx_eop(tx_cell==c && wn_tx[8]),.tx_err(1'b0),
        .rx_request(rx_req[c]),.rx_grant(rx_grant[c]),.crc_in(crc_in),.crc_ok(crc_ok),.rx_byte(rx_byte[c]),.rx_eop(rx_eop[c]),
        .rx_err(rx_err[c]),.out(out),.active(active),.word_pulse(word),.stop_pulse(stop),.rx_data(rxd),
        .status(st),.crc_absorb(l_absorb[c]),.crc_bit(l_bit[c]),.crc_emit(l_emit[c]));
      assign lraw={active,out,stop,word};
      assign oe[c]=0; assign ov[c]=0; assign tail[c]=0; assign cok[c]=0;
    end else if(kind(c)==COUNTER) begin: ct
      wire ge, hit; wire [7:0] count;
      wire [63:0] lines={30'b0,sinks[c][1],1'b0,29'b0,sinks[c][2],sinks[c][0],1'b0}; // 1 step 2 clear, 33 data
      wire pw=param_we && param_cell==c;   // a host write wins over nothing: loading is over by then
      fabric_counter t(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we((!loaded && load<3) || (loaded && pw)),
        .cfg_addr(loaded ? param_addr[1:0] : load[1:0]),.cfg_data(loaded ? param_data[12:0] : tw[load][12:0]),
        .cfg_bank(2'b11),.ctx_next(1'b0),.lines(lines),.ge(ge),.hit(hit),.count(count));
      assign lraw={2'b0,hit,ge};
      assign oe[c]=0; assign ov[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0; assign rx_eop[c]=0; assign rx_err[c]=0; assign tx_req[c]=0; assign held_grant[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0; assign tail[c]=0; assign cok[c]=0;
    end else if(kind(c)==LOGIC_K) begin: lg
      wire [3:0] lo;
      mesh_logic #(.ACTOR(ACTOR)) t(.clk(clk),.rst_n(rst_n),.run(run),.cfg({cc[TRANS_LSB+:56],cc[TRACK_LSB+48+:144],tile}),
        .in({xk,sinks[c]}),.hw(param_we && param_cell==c),.hdata(param_data[3:0]),.hmask(param_data[7:4]),.loc(lo));
      assign lraw=lo;
      assign oe[c]=0; assign ov[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0; assign rx_eop[c]=0; assign rx_err[c]=0; assign tx_req[c]=0; assign held_grant[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0; assign tail[c]=0; assign cok[c]=0;
    end else begin: cr
      wire ok, out, tl; wire [31:0] value;
      wire [63:0] lines={29'b0,sinks[c][4],sinks[c][3],1'b0,28'b0,sinks[c][2],sinks[c][1],sinks[c][0],1'b0}; // 1 init 2 absorb 3 emit, 33 data 34 level
      wire [1:0] la={(COL<COLS-1 && kind(NB_E)==SHIFTER) ? l_absorb[NB_E] : 1'b0, (COL>0 && kind(NB_W)==SHIFTER) ? l_absorb[NB_W] : 1'b0};
      wire [1:0] lb={(COL<COLS-1 && kind(NB_E)==SHIFTER) ? l_bit[NB_E] : 1'b0, (COL>0 && kind(NB_W)==SHIFTER) ? l_bit[NB_W] : 1'b0};
      wire [1:0] le={(COL<COLS-1 && kind(NB_E)==SHIFTER) ? l_emit[NB_E] : 1'b0, (COL>0 && kind(NB_W)==SHIFTER) ? l_emit[NB_W] : 1'b0};
      fabric_crc t(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we(!loaded),.cfg_addr(load),.cfg_data(tw[load]),
        .lines(lines),.link_absorb(la),.link_bit(lb),.link_emit(le),.out(out),.tail_out(tl),.ok(ok),.value(value));
      assign tail[c]=tl; assign cok[c]=ok;
      // At the word port local 1 is the reader's data-available, or the
      // serial out when bit 10 of the shape word (crc register 6; fabric_crc
      // keeps bits 9:0) selects it.
      assign lraw= c==WORD_PORT ? {tap_mismatch,tap_match,tile[16*6+10] ? out : rd_valid,ok} : {2'b0,out,ok};
      assign oe[c]=0; assign ov[c]=0; assign rx_req[c]=0; assign rx_byte[c]=0; assign rx_eop[c]=0; assign rx_err[c]=0; assign tx_req[c]=0; assign held_grant[c]=0;
      assign l_absorb[c]=0; assign l_bit[c]=0; assign l_emit[c]=0;
    end
    // A shifter's FIFOs connect to the word network if it is the
    // configured rx / tx cell; a receive FIFO otherwise feeds the host.
    assign rx_grant[c]= rx_cell==c ? rx_req[c] && wn_rx_ready : rx_req[c];
    assign tx_grant[c]= tx_cell==c ? tx_req[c] && wn_txv : held_grant[c];
    assign host_valid[c]= rx_cell!=c && rx_req[c];
    // Sticky flags for the host's waits.
    reg [3:0] seen_r;
    always @(posedge clk) if(!run || seen_clear) seen_r<=0; else seen_r<=seen_r|local_out[c];
    assign seen[4*c+:4]=seen_r;
    assign host_byte[8*c+:8]=rx_byte[c];
  end endgenerate

  integer p;
  always @* begin
    pad_oe=0; pad_out=0;
    for(p=0;p<N;p=p+1) begin pad_oe=pad_oe|oe[p]; pad_out=pad_out|ov[p]; end
  end

  wire [7:0] wrx=rx_byte[rx_cell<N ? rx_cell : 0];
  wire wrx_v= rx_cell<N && rx_req[rx_cell<N ? rx_cell : 0];
  wire [1:0] wrx_tag= rx_cell<N ? {rx_err[rx_cell<N ? rx_cell : 0], rx_eop[rx_cell<N ? rx_cell : 0]} : 2'b0;
  wire wtx_r= tx_cell<N && tx_req[tx_cell<N ? tx_cell : 0];
  wire wn_match, wn_ok; wire wn_st, wn_cap;
  wnet words(clk,rst_n,wc[31:0],wc[39:32],wc[47:40],wc[55:48],wc[63:56],wc[71:64],wc[87:72],wc[103:88],
    sinks[WORD_PORT][5],wn_match,wc[104],wc[108:105],tap_match,tap_mismatch,
    rd_data,rd_valid,rd_ready, {6'd0,wrx_tag,wrx},wrx_v,wn_rx_ready, 16'd0,1'b0,wn_st, 16'd0,1'b0,wn_cap,
    wr_data,wr_valid,wr_ready, wn_tx,wn_txv,wtx_r, wn_ok);
endmodule

// The logic tile: eight LUT4s with output registers and four host flags.
// Every output is a register, so the tile closes no combinational path
// (REG=1's invariant holds with any configuration).
// ACTOR=1 (ACTOR_FABRIC.md A2): the tile also has a control-actor mode,
// cfg[343] set: a state machine of four states over eight inputs in[7:0]
// (sinks 0-7). Per state s two rows at cfg[12s +: 12], row r at
// [12s+6r +: 6] = {next[5:4], event[3:0]} (event 0 none, 1-8 input 0-7):
// if row 0's event is high go to its next, else if row 1's, else stay;
// state 0 while stopped. Per state s and output k a select at
// cfg[48+16s+4k +: 4] (0 zero, 1 one, 2-9 input 0-7): the four locals are
// the current state's selections, combinational (as a contexted switch's
// sinks): the compiler refuses a configuration that closes a loop.
module mesh_logic #(parameter ACTOR=0)(input wire clk, rst_n, run, input wire [343:0] cfg, input wire [7:0] in,
  input wire hw, input wire [3:0] hdata, hmask, output wire [3:0] loc);
  reg [7:0] q;
  reg [3:0] h;
  always @(posedge clk)
    if(!rst_n || !run) h<=0;
    else if(hw) h<=(h & ~hmask) | (hdata & hmask);
  wire [31:0] pool={12'b0,1'b1,1'b0,h,q,in[5:0]};
  genvar k;
  generate for(k=0;k<8;k=k+1) begin: lut
    wire [39:0] f=cfg[40*k+:40];
    wire [3:0] idx={pool[f[35:31]],pool[f[30:26]],pool[f[25:21]],pool[f[20:16]]};
    wire [7:0] ens={1'b0,in[5:0],1'b1};
    wire [15:0] truth=f[15:0];
    always @(posedge clk)
      if(!rst_n || !run) q[k]<=f[39];
      else if(ens[f[38:36]]) q[k]<=truth[idx];
  end endgenerate
  if(ACTOR) begin: actor
    reg [1:0] st;
    wire [11:0] rows = st==2'd0 ? cfg[0+:12] : st==2'd1 ? cfg[12+:12] : st==2'd2 ? cfg[24+:12] : cfg[36+:12];
    wire [15:0] outs = st==2'd0 ? cfg[48+:16] : st==2'd1 ? cfg[64+:16] : st==2'd2 ? cfg[80+:16] : cfg[96+:16];
    wire [9:0] pick={in,1'b1,1'b0};          // 0 zero, 1 one, 2-9 input 0-7
    wire [8:0] ev={in,1'b0};                 // 0 none, 1-8 input 0-7
    wire ea = rows[3:0] < 4'd9 && ev[rows[3:0]], eb = rows[9:6] < 4'd9 && ev[rows[9:6]];
    always @(posedge clk)
      if(!rst_n || !run || !cfg[343]) st<=0;
      else if(ea) st<=rows[5:4];
      else if(eb) st<=rows[11:10];
    wire [3:0] o;
    genvar j;
    for(j=0;j<4;j=j+1) begin: out
      wire [3:0] s=outs[4*j+:4];
      assign o[j] = s < 4'd10 && pick[s];
    end
    assign loc = cfg[343] ? o : q[3:0];
  end else begin: plain
    assign loc = q[3:0];
  end
endmodule
`default_nettype wire
