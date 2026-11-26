`default_nettype none
// 5 x 3 heterogeneous experiment. All route and tile words are loaded while
// disarmed; unlike the preceding fabric there is no global source crossbar.
// Rows 0-2 (cells 0-8) keep their original configuration addresses. Rows 3-4
// (cells 9-14) repeat a column pattern: registered LUT4 cells in columns 0
// and 2, timers in column 1. Their words live at 128-184 and reset to zero,
// so images for the first nine cells leave them inert.
module grid_core(
  input wire clk,rst_n,arm,
  // Leaves 0-14 of grid_config_tree, one per cell: {valid,bank,addr[7:0],data[15:0]}.
  input wire [16*26-1:0] cfg_leaves,
  input wire trigger,input wire [1:0] pin_in,input wire [15:0] tx,tx1,
  output wire [15:0] rx,rx1,output wire busy,done,busy1,done1,
  output wire [2:0] pin_out,pin_oe,output wire configured,
  input wire temporal_enable,input wire [3:0] temporal_actions,input wire temporal_context,
  output wire temporal_tick,output wire [1:0] temporal_pins,output wire contexts_configured,
  input wire packet_mode,packet_running,packet_grant,input wire [7:0] packet_data,input wire packet_eop,
  output wire packet_request,packet_stop,packet_configured,packet_tick,
  output wire [1:0] seq_events,seq_event_enable,
  // Sequencer page loads commit all five alternate-context words at once.
  input wire ctx_load_we,input wire [79:0] ctx_load_data,
  // Lane B sequencer (cell 13). It starts with the host start, sees lane A's
  // activity as an event, and its actions are fabric sources in cells 12/14.
  input wire lane_b_start,lane_b_abort,lane_a_running,
  output wire lane_b_active,lane_b_done,lane_b_error,
  // Lane controller: pin edge events, and live writes of one alternate-context word.
  output wire [1:0] pin_edges,
  input wire ctx_word_we,input wire [2:0] ctx_word_idx,input wire [15:0] ctx_word_data,output wire ctx_word_ok,
  // Timer 0 and 1 capture registers (lane readback).
  output wire [15:0] timer0_captured,timer1_captured);
  localparam CELLS=15;
  // Configuration storage is distributed: every register is written only from
  // its own cell's leaf of grid_config_tree, so no configuration bus spans the
  // chip. Writes reach the leaves only while disarmed (see grid_config_tree).
  wire [15:0] cfg[0:62];
  wire [62:0] written;
  reg [11:0] crc_written;
  reg [5:0] coder_written;
  reg [5:0] coder_tick_select;
  reg coder_tail_required,crc_link_valid,coder_word_valid;
  reg [2:0] temporal_oe_gate;
  reg temporal_oe_gate_valid;
  reg [15:0] crc_routes[0:3];
  // Five sparse overrides form a second routing context. Each word is
  // {reserved[4:0], enable, alternate_selector[4:0], sink_index[4:0]}.
  wire [15:0] context_routes[0:4];
  wire [4:0] context_written;
  wire [4:0] context_valid;
  wire [9:0] context_unique;
  reg crc_shape_valid;
  reg [1:0] meta,sync,prev;
  wire [3:0] n_in[0:CELLS-1],s_in[0:CELLS-1],w_in[0:CELLS-1],e_in[0:CELLS-1];
  wire [3:0] n_out[0:CELLS-1],s_out[0:CELLS-1],w_out[0:CELLS-1],e_out[0:CELLS-1];
  wire [3:0] local_signal[0:CELLS-1];
  wire [45:0] sink;
  wire lane_b_ready;
  wire [3:0] lane_b_actions;
  // Extension words 128-184 (index 0-56): 24 switch words for cells 9-14
  // (12 bits), four LUT4 truth tables, 16 LUT4 input selectors, timer 2/3
  // words, six timer input selectors and the sequencer event inputs. Each
  // keeps a validity bit for reserved upper bits; they reset to zero.
  wire [15:0] ext_value[0:59];
  wire [59:0] ext_valid;
  wire [3:0] crc_in;
  wire [3:0] crc_route_valid;
  wire crc_out,crc_tail,crc_ok;
  wire [31:0] crc_value;
  wire coder_serial,coder_active,coder_absorb,coder_bit,coder_emit;
  wire coder_pulls,coder_rx_request,coder_rx_eop,coder_rx_err,coder_word;
  wire [7:0] coder_rx_byte;wire [15:0] coder_rx_data,coder_status;
  wire packet_configured_now=(&coder_written) && coder_word_valid && (!coder_tail_required ||
    (cfg[4][8] && (&crc_written) && crc_shape_valid && crc_link_valid));
  wire [35:0] switch_valid;
  wire [18:0] sink_valid;
  wire tick2,running2,tvalid2,level2,rise2,fall2,tick3,running3,tvalid3,level3,rise3,fall3;
  wire [15:0] timer_mode[0:3],timer_phase[0:3];  // words 208-215, see timer_words
  wire [3:0] timer_mode_ok;
  wire [3:0] ble_q;
  wire tick,running,tvalid,level,rise,fall,serial;
  wire tick1,running1,tvalid1,level1,rise1,fall1,serial1;
  wire live=arm && rst_n && configured;
  wire configured_now=temporal_oe_gate_valid && (&written) && (&switch_valid) && (&sink_valid) && tvalid && tvalid1 && cfg[2][15:7]==0 && cfg[2][4:0]>=1 && cfg[2][4:0]<=16 && cfg[55][15:7]==0 && cfg[55][4:0]>=1 && cfg[55][4:0]<=16 && cfg[3][15:4]==0 && cfg[4][15:9]==0 &&
    (!cfg[4][8] || ((&crc_written) && (&crc_route_valid) && crc_shape_valid)) && (&ext_valid) && lane_b_ready && (&timer_mode_ok);
  assign pin_oe=live ? cfg[4][2:0] & ~(cfg[4][5:3] & pin_out) &
    ~(temporal_enable ? temporal_oe_gate & {3{!temporal_actions[2]}} : 3'b0) : 0;
  assign pin_out={sink[9],sink[8],sink[7]};
  wire [14:0] leaf_we;
  wire [7:0] la[0:14];
  wire [15:0] ld[0:14];
  genvar k;
  generate for(k=0;k<15;k=k+1) begin: leaf
    assign leaf_we[k]=cfg_leaves[k*26+25] && !cfg_leaves[k*26+24];
    assign la[k]=cfg_leaves[k*26+16+:8];
    assign ld[k]=cfg_leaves[k*26+:16];
  end endgenerate
  // Words 0-62 belong to the cell whose tile or selectors they configure;
  // word 4 (pin enables, open drain, event polarity, CRC enable) to the I/O cell.
  genvar wi;
  generate for(wi=0;wi<63;wi=wi+1) begin: word
    localparam integer OWNER=(wi<=1)?2:(wi==2)?3:(wi==3)?4:(wi==4)?1:(wi<=40)?(wi-5)/4:
      (wi<=43)?2:(wi<=47)?3:(wi<=50)?1:(wi<=52)?4:(wi<=54)?5:(wi==55)?7:(wi<=58)?5:7;
    localparam [31:0] ADDR_FULL=wi;
    localparam [7:0] ADDR=ADDR_FULL[7:0];
    reg [15:0] value;
    reg done;
    wire hit=leaf_we[OWNER] && la[OWNER]==ADDR;
    always @(posedge clk) begin
      if(!rst_n) done<=0;else if(hit) done<=1;
      if(hit) value<=ld[OWNER];
    end
    assign cfg[wi]=value;
    assign written[wi]=done;
  end endgenerate
  genvar xi;
  generate for(xi=0;xi<60;xi=xi+1) begin: ext
    localparam integer LUT=(xi<24)?0:(xi<28)?xi-24:(xi<44)?(xi-28)/4:0;
    localparam integer LUT_CELL=(LUT==0)?9:(LUT==1)?11:(LUT==2)?12:14;
    localparam integer OWNER=(xi<24)?9+xi/4:(xi<44)?LUT_CELL:(xi<46 || (xi>=48 && xi<51))?10:(xi<54)?13:(xi<57)?6:13;
    localparam [31:0] ADDR_FULL=128+xi;
    localparam [7:0] ADDR=ADDR_FULL[7:0];
    reg [15:0] value;
    reg ok;
    wire hit=leaf_we[OWNER] && la[OWNER]==ADDR;
    wire [15:0] data=ld[OWNER];
    // Timer words (44-47) have no valid bit; word 56 checks its reserved bits.
    wire data_ok=(xi<24) ? data[15:12]==0 : (xi<28 || (xi>=44 && xi<48)) ? 1'b1 :
      (xi==56) ? data[15:2]==0 : data<=21;
    always @(posedge clk) begin
      if(!rst_n) begin value<=0;ok<=1;end
      else if(hit) begin value<=data;ok<=data_ok;end
    end
    assign ext_value[xi]=value;
    assign ext_valid[xi]=ok;
  end endgenerate
  // Sequencer cell 6: alternate-context words 112-116.
  genvar ci;
  generate for(ci=0;ci<5;ci=ci+1) begin: context_word
    localparam [31:0] ADDR_FULL=112+ci;
    localparam [7:0] ADDR=ADDR_FULL[7:0];
    reg [15:0] value;
    reg done;
    wire hit=leaf_we[6] && la[6]==ADDR;
    always @(posedge clk) begin
      if(!rst_n) done<=0;else if(hit || ctx_load_we || (ctx_word_we && ctx_word_idx==ci)) done<=1;
      if(ctx_load_we) value<=ctx_load_data[ci*16+:16];
      else if(ctx_word_we && ctx_word_idx==ci) value<=ctx_word_data;
      else if(hit) value<=ld[6];
    end
    assign context_routes[ci]=value;
    assign context_written[ci]=done;
  end endgenerate
  // CRC and coded-shifter cell 8: words 69-80 and 117-122.
  always @(posedge clk) begin
    if(!rst_n) begin crc_written<=0;coder_written<=0;coder_tick_select<=0;coder_tail_required<=0;crc_link_valid<=0;crc_shape_valid<=0;coder_word_valid<=1;end
    else if(leaf_we[8]) begin
      if(la[8]==118) coder_tick_select<=ld[8][5:0];
      // Coder word (register 5): stuffing after one equal bit never ends
      // (the stuff bit starts the next run, as in CAN), so N=1 is valid only
      // for runs of ones; Manchester does not combine with NRZI.
      if(la[8]==121) begin
        coder_tail_required<=|ld[8][14:9];
        coder_word_valid<=!(ld[8][2:0]==3'd1 && !ld[8][3]) && !(ld[8][15] && ld[8][4]);
      end
      if(la[8]>=117 && la[8]<=122) coder_written[la[8]-117]<=1;
      if(la[8]>=69 && la[8]<=80) begin
        crc_written[la[8]-69]<=1;
        if(la[8]==75) begin crc_shape_valid<=ld[8][15:7]==0;crc_link_valid<=ld[8][6];end
        if(la[8]>=77) crc_routes[la[8]-77]<=ld[8];
      end
    end
  end
  // Output I/O cell 1: temporal output-enable gating, word 123.
  always @(posedge clk) begin
    if(!rst_n) begin temporal_oe_gate<=0;temporal_oe_gate_valid<=1;end
    else if(leaf_we[1] && la[1]==123) begin temporal_oe_gate<=ld[1][2:0];temporal_oe_gate_valid<=ld[1][15:3]==0;end
  end
  always @(posedge clk) begin
    if(!rst_n) begin meta<=0;sync<=0;prev<=0;end
    else begin meta<=pin_in;sync<=meta;prev<=sync;end
  end
  // Event polarity is configurable independently for each synchronized pin.
  assign local_signal[0]={cfg[4][7] ? (!prev[1] && sync[1]) : (prev[1] && !sync[1]),
                          cfg[4][6] ? (!prev[0] && sync[0]) : (prev[0] && !sync[0]),sync[1],sync[0]};
  assign local_signal[1]=0;
  assign local_signal[2]={level,fall,rise,tick};
  assign local_signal[3]={serial | !busy,serial,done,busy};
  assign local_signal[4]={3'b0,cfg[3][{2'b00,sink[11],sink[10]}]};
  assign local_signal[5]={level1,fall1,rise1,tick1};
  assign local_signal[6]=temporal_enable ? {trigger,temporal_actions[2:0]} : {3'b0,trigger};
  assign local_signal[7]={serial1 | !busy1,serial1,done1,busy1};
  assign local_signal[8]={packet_mode && coder_active,packet_mode && coder_serial,crc_ok,crc_out};
  assign local_signal[9]={2'b0,!ble_q[0],ble_q[0]};
  assign local_signal[10]={level2,fall2,rise2,tick2};
  assign local_signal[11]={1'b0,lane_b_active,!ble_q[1],ble_q[1]};
  assign local_signal[12]={lane_b_actions[1:0],!ble_q[2],ble_q[2]};
  assign local_signal[13]={level3,fall3,rise3,tick3};
  assign local_signal[14]={lane_b_actions[3:2],!ble_q[3],ble_q[3]};
  genvar x;
  generate for(x=0;x<CELLS;x=x+1) begin: mesh
    if(x<3) assign n_in[x]=0; else assign n_in[x]=s_out[x-3];
    if(x>=CELLS-3) assign s_in[x]=0; else assign s_in[x]=n_out[x+3];
    if(x%3==0) assign w_in[x]=0; else assign w_in[x]=e_out[x-1];
    if(x%3==2) assign e_in[x]=0; else assign e_in[x]=w_out[x+1];
    if(x<9) begin: base
      grid_switch sw(n_in[x],s_in[x],w_in[x],e_in[x],local_signal[x],
        cfg[5+x*4][11:0],cfg[6+x*4][11:0],cfg[7+x*4][11:0],cfg[8+x*4][11:0],
        n_out[x],s_out[x],w_out[x],e_out[x]);
    end else begin: extension
      grid_switch sw(n_in[x],s_in[x],w_in[x],e_in[x],local_signal[x],
        ext_value[(x-9)*4][11:0],ext_value[(x-9)*4+1][11:0],ext_value[(x-9)*4+2][11:0],ext_value[(x-9)*4+3][11:0],
        n_out[x],s_out[x],w_out[x],e_out[x]);
    end
  end endgenerate
  genvar v;
  generate for(v=0;v<36;v=v+1) begin: switch_checks
    assign switch_valid[v]=cfg[5+v][15:12]==0;
  end endgenerate
  function automatic route_input;
    input [15:0] choice;input [3:0] local_bits,n,s,w,e;
    begin
      if(choice==0) route_input=0;
      else if(choice==1) route_input=1;
      else if(choice<6) route_input=local_bits[choice-2];
      else if(choice<10) route_input=n[choice-6];
      else if(choice<14) route_input=s[choice-10];
      else if(choice<18) route_input=w[choice-14];
      else if(choice<22) route_input=e[choice-18];
      else route_input=0;
    end
  endfunction
  genvar c;
  generate for(c=0;c<4;c=c+1) begin: crc_inputs
    assign crc_route_valid[c]=crc_routes[c]<=21;
    assign crc_in[c]=route_input(crc_routes[c],local_signal[8],n_in[8],s_in[8],w_in[8],e_in[8]);
  end endgenerate
  // CRC signal-space entries 0,1,2 and 32 are sourced by the four grid
  // selectors (absorb, emit, init, data). Direct legacy shifter links are not
  // exposed by this grid revision.
  wire [63:0] crc_lines={31'b0,crc_in[3],29'b0,crc_in[2],crc_in[1],crc_in[0]};
  assign packet_tick=crc_lines[coder_tick_select];
  fabric_crc crc_tile(clk,rst_n,live && cfg[4][8] && (!packet_mode || packet_running),leaf_we[8] && la[8]>=69 && la[8]<=76,
    la[8][2:0]-3'd5,ld[8],crc_lines,{1'b0,coder_absorb},{1'b0,coder_bit},
    {1'b0,coder_emit},crc_out,crc_tail,crc_ok,crc_value);
  fabric_shifter coded_tile(clk,rst_n,live && packet_mode && packet_running,
    leaf_we[8] && la[8]>=117 && la[8]<=122,la[8][2:0]-3'd4,ld[8],
    2'b11,1'b0,crc_lines,coder_pulls,packet_request,packet_grant,packet_data,packet_eop,1'b0,
    coder_rx_request,1'b0,crc_tail,coder_rx_byte,coder_rx_eop,coder_rx_err,coder_serial,
    coder_active,coder_word,packet_stop,coder_rx_data,coder_status,coder_absorb,coder_bit,coder_emit);
  wire unused_coder=&{1'b0,coder_pulls,coder_rx_request,coder_rx_eop,coder_rx_err,coder_word,
                       coder_rx_byte,coder_rx_data,coder_status};
  // Timer inputs 0..2, shifter inputs 3..6, IO outputs 7..9, LUT inputs 10..11.
  genvar z;
  generate for(z=0;z<5;z=z+1) begin: context_checks
    wire [4:0] target=context_routes[z][4:0];
    wire [4:0] selection=context_routes[z][9:5];
    assign context_valid[z]=context_routes[z][15:11]==0 &&
      (!context_routes[z][10] || (target<19 && selection<=21 &&
       ((target!=10 && target!=11) || selection<=1 || selection>=6)));
  end endgenerate
  assign context_unique[0]=!context_routes[0][10] || !context_routes[1][10] || context_routes[0][4:0]!=context_routes[1][4:0];
  assign context_unique[1]=!context_routes[0][10] || !context_routes[2][10] || context_routes[0][4:0]!=context_routes[2][4:0];
  assign context_unique[2]=!context_routes[0][10] || !context_routes[3][10] || context_routes[0][4:0]!=context_routes[3][4:0];
  assign context_unique[3]=!context_routes[1][10] || !context_routes[2][10] || context_routes[1][4:0]!=context_routes[2][4:0];
  assign context_unique[4]=!context_routes[1][10] || !context_routes[3][10] || context_routes[1][4:0]!=context_routes[3][4:0];
  assign context_unique[5]=!context_routes[2][10] || !context_routes[3][10] || context_routes[2][4:0]!=context_routes[3][4:0];
  assign context_unique[6]=!context_routes[0][10] || !context_routes[4][10] || context_routes[0][4:0]!=context_routes[4][4:0];
  assign context_unique[7]=!context_routes[1][10] || !context_routes[4][10] || context_routes[1][4:0]!=context_routes[4][4:0];
  assign context_unique[8]=!context_routes[2][10] || !context_routes[4][10] || context_routes[2][4:0]!=context_routes[4][4:0];
  assign context_unique[9]=!context_routes[3][10] || !context_routes[4][10] || context_routes[3][4:0]!=context_routes[4][4:0];
  wire contexts_configured_now=(&context_written) && (&context_valid) && (&context_unique);
  // A live write is checked against the same rules before it is accepted:
  // the word itself, and no other override may already claim its sink. The
  // controller fails closed on a refused write, so the armed configuration
  // never leaves the validity it was armed with.
  wire [4:0] live_target=ctx_word_data[4:0];
  wire [4:0] live_selection=ctx_word_data[9:5];
  wire live_word_valid=ctx_word_data[15:11]==0 && (!ctx_word_data[10] || (live_target<19 && live_selection<=21 &&
    ((live_target!=10 && live_target!=11) || live_selection<=1 || live_selection>=6)));
  wire [4:0] live_clash;
  genvar lc;
  generate for(lc=0;lc<5;lc=lc+1) begin: live_clash_check
    localparam [31:0] SLOT_FULL=lc;
    localparam [2:0] SLOT=SLOT_FULL[2:0];
    assign live_clash[lc]=ctx_word_idx!=SLOT && ctx_word_data[10] && context_routes[lc][10] &&
      context_routes[lc][4:0]==live_target;
  end endgenerate
  assign ctx_word_ok=ctx_word_idx<=3'd4 && live_word_valid && !(|live_clash);
  // Validity is a deep function of static configuration. It is registered
  // here and again in the scheduler; grid_config_tree holds arm off until
  // both stages reflect the last accepted write.
  reg configured_q,contexts_configured_q,packet_configured_q;
  always @(posedge clk) begin
    if(!rst_n) begin configured_q<=0;contexts_configured_q<=0;packet_configured_q<=0;end
    else begin configured_q<=configured_now;contexts_configured_q<=contexts_configured_now;packet_configured_q<=packet_configured_now;end
  end
  assign configured=configured_q;
  assign contexts_configured=contexts_configured_q;
  assign packet_configured=packet_configured_q;
  assign temporal_tick=tick;
  assign pin_edges=local_signal[0][3:2];
  assign temporal_pins=sync;
  genvar q;
  generate for(q=0;q<19;q=q+1) begin: inputs
    localparam integer CELL=(q<3)?2:(q<7)?3:(q<10)?1:(q<12)?4:(q<15)?5:7;
    localparam integer ADDR=(q<12)?41+q:56+q-12;
    localparam [31:0] SINK_INDEX_FULL=q;
    localparam [4:0] SINK_INDEX=SINK_INDEX_FULL[4:0];
    wire [15:0] choice=(temporal_enable && temporal_context && context_routes[0][10] && context_routes[0][4:0]==SINK_INDEX) ? {11'b0,context_routes[0][9:5]} :
      (temporal_enable && temporal_context && context_routes[1][10] && context_routes[1][4:0]==SINK_INDEX) ? {11'b0,context_routes[1][9:5]} :
      (temporal_enable && temporal_context && context_routes[2][10] && context_routes[2][4:0]==SINK_INDEX) ? {11'b0,context_routes[2][9:5]} :
      (temporal_enable && temporal_context && context_routes[3][10] && context_routes[3][4:0]==SINK_INDEX) ? {11'b0,context_routes[3][9:5]} :
      (temporal_enable && temporal_context && context_routes[4][10] && context_routes[4][4:0]==SINK_INDEX) ? {11'b0,context_routes[4][9:5]} : cfg[ADDR];
    if(q==10 || q==11) begin: logic_feedforward
      // No local LUT output can feed itself. The monotonic, fixed-class
      // neighbor routes cannot return a signal to its originating cell.
      assign sink_valid[q]=(cfg[ADDR]<=1) || (cfg[ADDR]>=6 && cfg[ADDR]<=21);
      assign sink[q]=route_input(choice,4'b0,n_in[CELL],s_in[CELL],w_in[CELL],e_in[CELL]);
    end else begin: regular_input
      assign sink_valid[q]=cfg[ADDR]<=21;
      assign sink[q]=route_input(choice,local_signal[CELL],n_in[CELL],s_in[CELL],w_in[CELL],e_in[CELL]);
    end
  end endgenerate
  // Timer mode words 208-215: {mode, phase} for timers 0-3, each written
  // from its timer's cell (2, 5, 10, 13). Mode {limit[15:8], reserved[7:2],
  // function[1:0]}: 0 hold (the reset value, so earlier images are
  // unchanged), 1 count, 2 capture, 3 resync (see grid_timer). Reserved
  // bits must be zero. Live first/period writes arrive with lane ownership
  // (step 2.5); until then they are tied off.
  genvar ti;
  generate for(ti=0;ti<4;ti=ti+1) begin: timer_words
    localparam integer CELL=(ti==0)?2:(ti==1)?5:(ti==2)?10:13;
    localparam [7:0] MODE_ADDR=8'd208+2*ti;
    localparam [7:0] PHASE_ADDR=8'd209+2*ti;
    reg [15:0] mode_q,phase_q;
    always @(posedge clk) begin
      if(!rst_n) begin mode_q<=0;phase_q<=0;end
      else begin
        if(leaf_we[CELL] && la[CELL]==MODE_ADDR) mode_q<=ld[CELL];
        if(leaf_we[CELL] && la[CELL]==PHASE_ADDR) phase_q<=ld[CELL];
      end
    end
    assign timer_mode[ti]=mode_q;
    assign timer_phase[ti]=phase_q;
    assign timer_mode_ok[ti]=mode_q[7:2]==0;
  end endgenerate
  wire [15:0] captured2,captured3;
  wire unused_captures=&{1'b0,captured2,captured3};
  grid_timer timer(clk,rst_n,live,leaf_we[2] && (la[2]==0 || la[2]==1),
    la[2]==0 ? ld[2] : cfg[0],la[2]==1 ? ld[2] : cfg[1],1'b0,16'b0,16'b0,timer_mode[0],timer_phase[0],
    sink[0],sink[1],sink[2],tick,running,tvalid,level,rise,fall,timer0_captured);
  fabric_v2_shift shifter(clk,rst_n,live,sink[3],sink[4],sink[5],cfg[2][4:0],cfg[2][5],cfg[2][6],
    tx,sink[6],serial,rx,busy,done);
  grid_timer timer1(clk,rst_n,live,leaf_we[5] && (la[5]==53 || la[5]==54),
    la[5]==53 ? ld[5] : cfg[53],la[5]==54 ? ld[5] : cfg[54],1'b0,16'b0,16'b0,timer_mode[1],timer_phase[1],
    sink[12],sink[13],sink[14],tick1,running1,tvalid1,level1,rise1,fall1,timer1_captured);
  fabric_v2_shift shifter1(clk,rst_n,live,sink[15],sink[16],sink[17],cfg[55][4:0],cfg[55][5],cfg[55][6],
    tx1,sink[18],serial1,rx1,busy1,done1);
  // Extension sinks 19-42 have no alternate-context overrides. Each selector
  // reads constants, its own cell's local outputs or a neighbor's tracks.
  // Sinks: 19-21 timer2, 22-24 timer3, 25-40 LUT4 cells 0-3 inputs a-d,
  // 41-42 sequencer event inputs (in the sequencer's cell 6), 43-45 lane B
  // event inputs (in lane B's cell 13).
  genvar y;
  generate for(y=19;y<46;y=y+1) begin: ext_inputs
    localparam integer CELL=(y<22)?10:(y<25)?13:(y<29)?9:(y<33)?11:(y<37)?12:(y<41)?14:(y<43)?6:13;
    // Selectors: 25-40 at extension words 28-43, 19-24 at 48-53, 41-42 at
    // 54-55, 43-45 at 57-59 (words 185-187).
    localparam integer EXT=(y>=43) ? y+14 : (y>=41) ? y+13 : (y<25) ? y+29 : y+3;
    wire [4:0] choice=ext_value[EXT][4:0];
    assign sink[y]=route_input({11'b0,choice},local_signal[CELL],n_in[CELL],s_in[CELL],w_in[CELL],e_in[CELL]);
  end endgenerate
  assign seq_events={sink[42],sink[41]};
  assign seq_event_enable=ext_value[56][1:0];
  grid_timer timer2(clk,rst_n,live,leaf_we[10] && (la[10]==172 || la[10]==173),
    la[10]==172 ? ld[10] : ext_value[44],la[10]==173 ? ld[10] : ext_value[45],1'b0,16'b0,16'b0,timer_mode[2],timer_phase[2],
    sink[19],sink[20],sink[21],tick2,running2,tvalid2,level2,rise2,fall2,captured2);
  grid_timer timer3(clk,rst_n,live,leaf_we[13] && (la[13]==174 || la[13]==175),
    la[13]==174 ? ld[13] : ext_value[46],la[13]==175 ? ld[13] : ext_value[47],1'b0,16'b0,16'b0,timer_mode[3],timer_phase[3],
    sink[22],sink[23],sink[24],tick3,running3,tvalid3,level3,rise3,fall3,captured3);
  genvar b;
  generate for(b=0;b<4;b=b+1) begin: lut4
    grid_lut4_cell tile(clk,rst_n,live,ext_value[24+b],{sink[28+4*b],sink[27+4*b],sink[26+4*b],sink[25+4*b]},ble_q[b]);
  end endgenerate
  // Lane B: a second sequencer that lives with the cells it drives. Its rows
  // (words 192-207) and settings (word 188: {reserved[15:10], clear[9],
  // enable[8], idle_actions[7:4], entry[3:0]}) come from cell 13's leaf.
  // Events: always, timer 2 tick, timer 3 tick, routed sinks 43-45, lane A
  // running. Actions 1:0 are cell 12 sources 3:2, actions 3:2 are cell 14
  // sources 3:2; cell 11 source 2 is lane B active.
  reg lane_b_enable,lane_b_settings_valid;
  reg [3:0] lane_b_entry,lane_b_idle;
  always @(posedge clk) begin
    if(!rst_n) begin lane_b_enable<=0;lane_b_settings_valid<=1;lane_b_entry<=0;lane_b_idle<=0;end
    else if(leaf_we[13] && la[13]==188) begin
      lane_b_enable<=ld[13][8];lane_b_idle<=ld[13][7:4];lane_b_entry<=ld[13][3:0];
      lane_b_settings_valid<=ld[13][15:10]==0;
    end
  end
  wire [15:0] lane_b_programmed;
  wire [3:0] lane_b_seq_actions,lane_b_state,lane_b_load_page;
  wire lane_b_halting,lane_b_loading;
  assign lane_b_ready=lane_b_settings_valid && (!lane_b_enable || lane_b_programmed[lane_b_entry]);
  grid_sequencer lane_b(clk,rst_n,live && lane_b_enable,
    leaf_we[13] && la[13][7:4]==4'hC,la[13][3:0],ld[13],leaf_we[13] && la[13]==188 && ld[13][9],
    lane_b_start,lane_b_abort,lane_b_entry,
    {1'b0,lane_a_running,sink[45],sink[44],sink[43],tick3,tick2,1'b1},
    lane_b_seq_actions,lane_b_halting,lane_b_active,lane_b_done,lane_b_error,lane_b_state,lane_b_programmed,
    1'b0,4'b0,lane_b_loading,lane_b_load_page,1'b0,4'b0,16'b0,1'b0);
  assign lane_b_actions=lane_b_active ? lane_b_seq_actions : lane_b_idle;
  wire unused_ext=&{1'b0,running2,tvalid2,running3,tvalid3,cfg_leaves[16*26-1:15*26],
                     lane_b_halting,lane_b_loading,lane_b_load_page,lane_b_state};
endmodule

// Registered configuration distribution: one root register next to the host
// link feeds one leaf register per cell (0-14) plus leaf 15 for the stream
// scheduler. A leaf drives only its own cell's configuration registers, so
// no configuration net spans the chip; the root drives 16 leaves. A write is
// visible in its cell's registers three cycles after it is accepted; busy
// covers those cycles so the fabric can hold arm off until every accepted
// write has landed. Bank-route commands travel the same path, preserving
// their order relative to word 88.
module grid_config_tree(
  input wire clk,rst_n,accept,bank,input wire [7:0] addr,input wire [15:0] data,
  output wire [16*26-1:0] leaves,output wire busy);
  reg root_valid; reg [2:0] trail;
  reg [24:0] root_bus;
  always @(posedge clk) begin
    if(!rst_n) begin root_valid<=0;trail<=0;end
    else begin root_valid<=accept;trail<={trail[1:0],root_valid};end
    root_bus<={bank,addr,data};
  end
  // A write lands in its cell register 3 clocks after acceptance; the two
  // registered validity stages need 2 more before the fabric may arm.
  assign busy=root_valid || (|trail);
  genvar k;
  generate for(k=0;k<16;k=k+1) begin: leaf
    reg valid;
    reg [24:0] bus;
    // keep: the leaves have identical inputs; merging them would restore a broadcast.
    (* keep *) always @(posedge clk) begin
      if(!rst_n) valid<=0;else valid<=root_valid;
      bus<=root_bus;
    end
    assign leaves[k*26+:26]={valid,bus};
  end endgenerate
endmodule
`default_nettype wire
