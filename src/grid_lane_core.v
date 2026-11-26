`default_nettype none
// Lane core: one lane controller with the tiles it times bits with, wired by
// construction through a local signal set, plus a narrow interface to pads
// and the mesh (experiments/grid_fabric/LANE_CORE.md).
//
// Parts: grid_lane_controller; two grid_timer; fabric_shifter (the coded
// shifter: parity, stuffing, NRZI, Manchester, receive decode, CRC link);
// fabric_crc (polynomial or additive), linked to the coded shifter.
//
// Local signal set, 64 lines; every tile input selects one with a 6-bit
// index (fabric_shifter and fabric_crc already work this way). Every line
// is a register output (tile outputs already are; FIRE, SHIFT and the coder
// word/stop pulses are registered here), so no selection can close a
// combinational loop: a pulse reaches the tile it drives one clock after
// its source. Pulses 0-31, levels 32-63:
//    0 never            1 FIRE (the instruction only; the controller's
//                         fire after a SHIFT is not on it)
//    2 SHIFT (the coder's data register takes the tx word)
//    3 timer0 tick      4 timer0 rise      5 timer0 fall
//    6 timer1 tick      7 timer1 rise      8 timer1 fall
//    9 coder word      10 coder stop
//   11 in0 rise        12 in0 fall        13 in1 rise        14 in1 fall
//   15 mesh0 rise      16 mesh0 fall      17 mesh1 rise      18 mesh1 fall
//   32 low             33 high
//   34-37 actions 0-3
//   38 timer0 level    39 timer0 running  40 timer1 level    41 timer1 running
//   42 coder serial    43 coder active    44 CRC out         45 CRC ok
//   46 in0             47 in1             48 mesh0           49 mesh1
//   50 coder word bad (the last received word failed parity, a post bit,
//      stuffing or Manchester)
// Every other index is reserved: selecting it is invalid configuration.
//
// Configuration words (lane-local index; the chip maps them to a page):
//    0-3   timer0 first, period, mode, phase
//    4-7   timer1 first, period, mode, phase
//    8     {timer0 stop[11:6],  timer0 start[5:0]}
//    9     {timer1 start[11:6], timer0 aux[5:0]}
//   10     {timer1 aux[11:6],   timer1 stop[5:0]}
//   11-16  coded shifter registers 1-6 (register 0, the data word, is
//          written by the controller's SHIFT)
//   17-24  CRC registers 0-7
//   25-28  event selectors, two per word {event 2k+1[11:6], event 2k[5:0]}
//   29-32  level selectors, two per word
//   33-35  outputs k: {enable[11:6], value[5:0]}
//   36     program {last[15:10], base[9:0]}
//   37     settings {idle actions[7:4]}
// Bits [15:12] of selector words, and settings bits other than [7:4], are
// reserved and must be zero.
//
// Readback slots: 0 coder rx word, 1 coder status, 2/3 timer0/1 capture,
// 4/5 CRC value low/high, 6 {mesh, inputs}, 7-9 from the fabric (stream
// bytes left, bytes written, stream status), 10-15 zero.
//
// Streams: the coded shifter owns the reader when its auto pull is set and
// the writer when its auto push is set; otherwise the controller's PULL and
// PUSH do. A controller PULL or PUSH on a stream the shifter owns is a
// stream fault (`stream_fault`), which the fabric turns into an abort.
module grid_lane_core #(parameter USE_MACRO=0)(
  input wire clk,rst_n,
  input wire arm,                     // fabric armed and this lane's configuration valid
  input wire cfg_we,input wire [5:0] cfg_addr,input wire [15:0] cfg_data,
  output wire configured,
  input wire start,abort,
  output wire mem_req,input wire mem_ready,output wire [9:0] mem_addr,
  input wire mem_rvalid,input wire [7:0] mem_rdata,
  output wire owns_port,resp_pending,
  input wire rd_valid,input wire [7:0] rd_data,output wire rd_consume,rd_want,
  output wire wr_valid,output wire [7:0] wr_data,input wire wr_ready,
  output wire stream_fault,
  input wire [1:0] pad_in,mesh_in,   // synchronized levels (registered again here)
  output wire [2:0] out_value,out_enable,
  input wire [47:0] fabric_readback,
  output wire active,loading,done,error
`ifdef FORMAL
  // The configuration words, flattened (word k at [16k+15:16k]), for the
  // validity proof in formal/grid_lane_core.
  ,output wire [38*16-1:0] f_words
`endif
);
  // ------------------------------------------------------------ config
  reg [15:0] word[0:37];
  wire ctl_cfg_we;wire [7:0] ctl_cfg_addr;wire [15:0] ctl_cfg_data;
  integer wi;
  always @(posedge clk) begin
    if(!rst_n) begin
      for(wi=0;wi<38;wi=wi+1) word[wi]<=16'd0;
    end else if(cfg_we && cfg_addr<6'd38) word[cfg_addr]<=cfg_data;
    else if(ctl_cfg_we) word[{3'b0,ctl_cfg_addr[2:0]}]<=ctl_cfg_data;
  end
  wire [5:0] t0_start_sel=word[8][5:0],t0_stop_sel=word[8][11:6],t0_aux_sel=word[9][5:0];
  wire [5:0] t1_start_sel=word[9][11:6],t1_stop_sel=word[10][5:0],t1_aux_sel=word[10][11:6];
  wire [5:0] ev_sel[0:7],lv_sel[0:7];
  genvar si;
`ifdef FORMAL
  generate for(si=0;si<38;si=si+1) begin: formal_words
    assign f_words[16*si+15:16*si]=word[si];
  end endgenerate
`endif
  generate for(si=0;si<4;si=si+1) begin: selector_words
    assign ev_sel[2*si]=word[25+si][5:0];assign ev_sel[2*si+1]=word[25+si][11:6];
    assign lv_sel[2*si]=word[29+si][5:0];assign lv_sel[2*si+1]=word[29+si][11:6];
  end endgenerate
  wire [5:0] ov_sel[0:2],oe_sel[0:2];
  generate for(si=0;si<3;si=si+1) begin: output_words
    assign ov_sel[si]=word[33+si][5:0];assign oe_sel[si]=word[33+si][11:6];
  end endgenerate

  // ------------------------------------------------------------ lines
  wire [63:0] lines;
  wire fire,shift_go;
  reg fire_q,shift_q,c_word_q,c_stop_q;
  wire [3:0] actions;
  wire t0_tick,t0_rise,t0_fall,t0_level,t0_running,t0_cfg;
  wire t1_tick,t1_rise,t1_fall,t1_level,t1_running,t1_cfg;
  wire c_word,c_stop,c_out,c_active,c_bad;
  wire crc_out,crc_ok;
  // Inputs are registered at the boundary (pad_q, mesh_q), so their level
  // and edge lines are register outputs like every other line: a mesh input
  // that is combinationally derived from this core's own outputs cannot
  // close a loop through a selector.
  reg [1:0] pad_q,mesh_q,pad_prev,mesh_prev;
  always @(posedge clk) begin
    if(!rst_n) begin pad_q<=0;mesh_q<=0;pad_prev<=0;mesh_prev<=0;fire_q<=0;shift_q<=0;c_word_q<=0;c_stop_q<=0;end
    else begin
      pad_q<=pad_in;mesh_q<=mesh_in;pad_prev<=pad_q;mesh_prev<=mesh_q;
      fire_q<=fire && !shift_q;shift_q<=shift_go;c_word_q<=c_word;c_stop_q<=c_stop;
    end
  end
  wire [1:0] pad_rise=pad_q&~pad_prev,pad_fall=~pad_q&pad_prev;
  wire [1:0] mesh_rise=mesh_q&~mesh_prev,mesh_fall=~mesh_q&mesh_prev;
  assign lines={13'b0,c_bad,mesh_q[1],mesh_q[0],pad_q[1],pad_q[0],crc_ok,crc_out,c_active,c_out,
                t1_running,t1_level,t0_running,t0_level,actions[3],actions[2],actions[1],actions[0],1'b1,1'b0,
                13'b0,mesh_fall[1],mesh_rise[1],mesh_fall[0],mesh_rise[0],pad_fall[1],pad_rise[1],pad_fall[0],pad_rise[0],
                c_stop_q,c_word_q,t1_fall,t1_rise,t1_tick,t0_fall,t0_rise,t0_tick,shift_q,fire_q,1'b0};
  // A defined line: pulses 0-18, levels 32-50.
  function automatic line_ok(input [5:0] s);
    line_ok=s<=6'd18 || (s>=6'd32 && s<=6'd50);
  endfunction
  function automatic level_ok(input [4:0] s);   // a level index (32 + s)
    level_ok=s<=5'd18;
  endfunction

  // ------------------------------------------------------------ controller
  wire [255:0] readback;
  wire [7:0] events,levels;
  genvar ei;
  generate for(ei=0;ei<8;ei=ei+1) begin: event_lines
    assign events[ei]=lines[ev_sel[ei]];
    assign levels[ei]=lines[lv_sel[ei]];
  end endgenerate
  wire [15:0] tx_word;
  wire ctl_rd_valid,ctl_rd_consume,ctl_wr_valid,ctl_wr_ready;
  wire [7:0] ctl_wr_data;
  wire [5:0] pc;wire [15:0] acc;wire [7:0] count;
  wire ctl_rd_want;
  // Live writes (WCFG, while armed): the controller owns words 0-7 and the
  // core accepts timer first and period (words 0, 1, 4, 5) of a timer in
  // use, nonzero. The word is updated and the timer's shadow takes the new
  // {first, period} at its next reload, so a running period is never cut.
  wire [2:0] live_idx=ctl_cfg_addr[2:0];
  wire live_ok=ctl_cfg_addr<=8'd7 && !live_idx[1] && ctl_cfg_data!=16'd0 &&
    (live_idx[2] ? word[4]!=16'd0 : word[0]!=16'd0);
  wire [15:0] live_first=live_idx[0] ? word[{3'b0,live_idx[2],2'b00}] : ctl_cfg_data;
  wire [15:0] live_period=live_idx[0] ? ctl_cfg_data : word[{3'b0,live_idx[2],2'b01}];
  grid_lane_controller #(.USE_MACRO(USE_MACRO),.OWN_FIRST(8'd0),.OWN_LAST(8'd7)) ctl(clk,rst_n,arm && configured,start,abort,
    word[36][9:0],word[36][15:10],
    mem_req,mem_ready,mem_addr,mem_rvalid,mem_rdata,owns_port,resp_pending,
    events,levels,readback,word[37][7:4],
    actions,fire,tx_word,shift_go,
    ctl_rd_valid,rd_data,ctl_rd_consume,ctl_rd_want,ctl_wr_valid,ctl_wr_data,ctl_wr_ready,
    ctl_cfg_we,ctl_cfg_addr,ctl_cfg_data,live_ok,
    active,loading,done,error,pc,acc,count);
  wire unused_ctl=&{1'b0,pc,acc,count};

  // ------------------------------------------------------------ timers
  wire [15:0] t0_captured,t1_captured;
  grid_timer timer0(clk,rst_n,arm && configured,cfg_we && (cfg_addr==6'd0 || cfg_addr==6'd1),
    cfg_addr==6'd0 ? cfg_data : word[0],cfg_addr==6'd1 ? cfg_data : word[1],
    ctl_cfg_we && !live_idx[2],live_first,live_period,word[2],word[3],
    lines[t0_start_sel],lines[t0_stop_sel],lines[t0_aux_sel],
    t0_tick,t0_running,t0_cfg,t0_level,t0_rise,t0_fall,t0_captured);
  grid_timer timer1(clk,rst_n,arm && configured,cfg_we && (cfg_addr==6'd4 || cfg_addr==6'd5),
    cfg_addr==6'd4 ? cfg_data : word[4],cfg_addr==6'd5 ? cfg_data : word[5],
    ctl_cfg_we && live_idx[2],live_first,live_period,word[6],word[7],
    lines[t1_start_sel],lines[t1_stop_sel],lines[t1_aux_sel],
    t1_tick,t1_running,t1_cfg,t1_level,t1_rise,t1_fall,t1_captured);
  // A timer is in use when its first and period are set; an unused timer
  // leaves both zero. Its mode reserved bits must be zero either way.
  wire t0_ok=(word[0]!=0)==(word[1]!=0) && word[2][7:2]==0 && (t0_cfg || word[0]==0);
  wire t1_ok=(word[4]!=0)==(word[5]!=0) && word[6][7:2]==0 && (t1_cfg || word[4]==0);

  // ------------------------------------------------------------ coded shifter and CRC
  wire c_pulls,c_tx_request,c_rx_request,c_rx_eop,c_rx_err;
  wire [7:0] c_rx_byte;wire [15:0] c_rx_data,c_status;
  wire c_absorb,c_bit,c_emit,crc_tail;
  wire [31:0] crc_value;
  wire c_auto_pull=word[13][11],c_auto_push=word[13][12];
  wire c_tx_grant=c_tx_request && c_auto_pull && rd_valid;
  wire c_rx_grant=c_rx_request && c_auto_push && wr_ready;
  fabric_shifter coded_shifter(.clk(clk),.rst_n(rst_n),.enable(arm && configured),
    // SHIFT: the controller registers its tx word on the SHIFT clock, so
    // the data register is written one clock later, on the shift line
    // (shift_q), when the word is current; a start on that line takes it.
    .cfg_we((cfg_we && cfg_addr>=6'd11 && cfg_addr<=6'd16) || shift_q),
    .cfg_addr(shift_q ? 3'd0 : cfg_addr[2:0]-3'd2),.cfg_data(shift_q ? tx_word : cfg_data),
    .cfg_bank(2'b11),.ctx_next(1'b0),.lines(lines),.pulls(c_pulls),
    .tx_request(c_tx_request),.tx_grant(c_tx_grant),.tx_data(rd_data),.tx_eop(1'b0),.tx_err(1'b0),
    .rx_request(c_rx_request),.rx_grant(c_rx_grant),.crc_in(crc_tail),.rx_byte(c_rx_byte),
    .rx_eop(c_rx_eop),.rx_err(c_rx_err),.out(c_out),.active(c_active),.word_pulse(c_word),.stop_pulse(c_stop),
    .rx_data(c_rx_data),.status(c_status),.crc_absorb(c_absorb),.crc_bit(c_bit),.crc_emit(c_emit));
  assign c_bad=c_status[6];
  fabric_crc crc_tile(.clk(clk),.rst_n(rst_n),.enable(arm && configured),
    .cfg_we(cfg_we && cfg_addr>=6'd17 && cfg_addr<=6'd24),.cfg_addr(cfg_addr[2:0]-3'd1),.cfg_data(cfg_data),
    .lines(lines),.link_absorb({1'b0,c_absorb}),.link_bit({1'b0,c_bit}),.link_emit({1'b0,c_emit}),
    .out(crc_out),.tail_out(crc_tail),.ok(crc_ok),.value(crc_value));
  wire unused_coder=&{1'b0,c_pulls,c_rx_eop,c_rx_err};

  // ------------------------------------------------------------ streams
  assign rd_consume=c_auto_pull ? c_tx_grant : ctl_rd_consume;
  assign ctl_rd_valid=!c_auto_pull && rd_valid;
  assign rd_want=!c_auto_pull && ctl_rd_want;
  assign wr_valid=c_auto_push ? c_rx_request : ctl_wr_valid;
  assign wr_data=c_auto_push ? c_rx_byte : ctl_wr_data;
  assign ctl_wr_ready=!c_auto_push && wr_ready;
  assign stream_fault=(c_auto_pull && ctl_rd_want) || (c_auto_push && ctl_wr_valid);

  // ------------------------------------------------------------ readback and outputs
  assign readback={96'b0,fabric_readback,{12'b0,mesh_q,pad_q},crc_value,t1_captured,t0_captured,c_status,c_rx_data};
  generate for(si=0;si<3;si=si+1) begin: outputs
    assign out_value[si]=lines[ov_sel[si]];
    assign out_enable[si]=lines[oe_sel[si]];
  end endgenerate

  // ------------------------------------------------------------ validity
  reg sel_ok;
  integer k;
  always @(*) begin
    sel_ok=line_ok(t0_start_sel) && line_ok(t0_stop_sel) && line_ok(t0_aux_sel) &&
           line_ok(t1_start_sel) && line_ok(t1_stop_sel) && line_ok(t1_aux_sel) &&
           word[8][15:12]==0 && word[9][15:12]==0 && word[10][15:12]==0;
    for(k=0;k<8;k=k+1) sel_ok=sel_ok && line_ok(ev_sel[k]) && line_ok(lv_sel[k]);
    for(k=0;k<3;k=k+1) sel_ok=sel_ok && line_ok(ov_sel[k]) && line_ok(oe_sel[k]);
    for(k=0;k<4;k=k+1) sel_ok=sel_ok && word[25+k][15:12]==0 && word[29+k][15:12]==0;
    for(k=0;k<3;k=k+1) sel_ok=sel_ok && word[33+k][15:12]==0;
  end
  // Coded shifter lines (register 2 step, 3 io, 4 burst, 6 coder2) and its
  // coder word rules; CRC lines (registers 4, 5, 7) and shape rules.
  wire coder_ok=line_ok(word[12][5:0]) && line_ok(word[12][11:6]) && word[12][15:12]==0 &&
    line_ok(word[13][5:0]) && level_ok(word[13][10:6]) && word[13][15:13]==0 &&
    level_ok(word[14][4:0]) && line_ok(word[14][12:7]) && word[14][15:13]==0 &&
    !(word[15][2:0]==3'd1 && !word[15][3]) && !(word[15][15] && word[15][4]) &&
    level_ok(word[16][4:0]) && word[16][15:14]==0;
  wire crc_ok_cfg=line_ok(word[21][5:0]) && level_ok(word[21][10:6]) && word[21][15:11]==0 &&
    line_ok(word[22][5:0]) && word[22][10:6]<=5'd18 && word[22][15:11]==0 &&
    word[23][15:10]==0 && !word[23][7] && !(word[23][9] && !word[23][8]) &&
    level_ok(word[24][4:0]) && level_ok(word[24][10:6]) && word[24][15:12]==0;
  wire settings_ok=word[37][15:8]==0 && word[37][3:0]==0;
  assign configured=sel_ok && coder_ok && crc_ok_cfg && settings_ok && t0_ok && t1_ok;
endmodule
`default_nettype wire
