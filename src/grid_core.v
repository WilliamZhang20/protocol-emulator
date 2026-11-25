`default_nettype none
// 5 x 3 heterogeneous experiment. All route and tile words are loaded while
// disarmed; unlike the preceding fabric there is no global source crossbar.
// Rows 0-2 (cells 0-8) keep their original configuration addresses. Rows 3-4
// (cells 9-14) repeat a column pattern: registered LUT4 cells in columns 0
// and 2, timers in column 1. Their words live at 128-184 and reset to zero,
// so images for the first nine cells leave them inert.
module grid_core(
  input wire clk,rst_n,arm,cfg_we,
  input wire [7:0] cfg_addr,input wire [15:0] cfg_data,
  input wire trigger,input wire [1:0] pin_in,input wire [15:0] tx,tx1,
  output wire [15:0] rx,rx1,output wire busy,done,busy1,done1,
  output wire [2:0] pin_out,pin_oe,output wire configured,
  input wire temporal_enable,input wire [3:0] temporal_actions,input wire temporal_context,
  output wire temporal_tick,output wire [1:0] temporal_pins,output wire contexts_configured,
  input wire packet_mode,packet_running,packet_grant,input wire [7:0] packet_data,input wire packet_eop,
  output wire packet_request,packet_stop,packet_configured,packet_tick,
  output wire [1:0] seq_events,seq_event_enable);
  localparam CELLS=15;
  reg [15:0] cfg[0:62];
  reg [62:0] written;
  reg [11:0] crc_written;
  reg [5:0] coder_written;
  reg [5:0] coder_tick_select;
  reg coder_tail_required,crc_link_valid;
  reg [2:0] temporal_oe_gate;
  reg temporal_oe_gate_valid;
  reg [15:0] crc_routes[0:3];
  // Five sparse overrides form a second routing context. Each word is
  // {reserved[4:0], enable, alternate_selector[4:0], sink_index[4:0]}.
  reg [15:0] context_routes[0:4];
  reg [4:0] context_written;
  wire [4:0] context_valid;
  wire [9:0] context_unique;
  reg crc_shape_valid;
  reg [1:0] meta,sync,prev;
  wire [3:0] n_in[0:CELLS-1],s_in[0:CELLS-1],w_in[0:CELLS-1],e_in[0:CELLS-1];
  wire [3:0] n_out[0:CELLS-1],s_out[0:CELLS-1],w_out[0:CELLS-1],e_out[0:CELLS-1];
  wire [3:0] local_signal[0:CELLS-1];
  wire [42:0] sink;
  // Extension words 128-184: 24 switch words for cells 9-14 (12 bits), four
  // LUT4 truth tables, 26 tile-input selectors (5 bits) and the sequencer
  // event-input enables. Each keeps a validity bit for reserved upper bits.
  reg [11:0] ext_switch[0:23];
  reg [15:0] ext_truth[0:3];
  reg [4:0] ext_select[0:21];
  reg [15:0] timer_word[0:3];
  reg [4:0] seq_select[0:1];
  reg [1:0] seq_enable;
  reg [56:0] ext_valid;
  wire ext_write=!arm && cfg_we && cfg_addr>=128 && cfg_addr<=184;
  wire [7:0] ext_index=cfg_addr-8'd128;
  wire [7:0] select_offset=ext_index<44 ? ext_index-8'd28 : ext_index-8'd32;
  wire [4:0] select_index=select_offset[4:0];
  wire [3:0] crc_in;
  wire [3:0] crc_route_valid;
  wire crc_out,crc_tail,crc_ok;
  wire [31:0] crc_value;
  wire coder_serial,coder_active,coder_absorb,coder_bit,coder_emit;
  wire coder_pulls,coder_rx_request,coder_rx_eop,coder_rx_err,coder_word;
  wire [7:0] coder_rx_byte;wire [15:0] coder_rx_data,coder_status;
  assign packet_configured=(&coder_written) && (!coder_tail_required ||
    (cfg[4][8] && (&crc_written) && crc_shape_valid && crc_link_valid));
  wire [35:0] switch_valid;
  wire [18:0] sink_valid;
  wire tick2,running2,tvalid2,level2,rise2,fall2,tick3,running3,tvalid3,level3,rise3,fall3;
  wire [3:0] ble_q;
  wire tick,running,tvalid,level,rise,fall,serial;
  wire tick1,running1,tvalid1,level1,rise1,fall1,serial1;
  wire live=arm && rst_n && configured;
  assign configured=temporal_oe_gate_valid && (&written) && (&switch_valid) && (&sink_valid) && tvalid && tvalid1 && cfg[2][15:6]==0 && cfg[2][4:0]>=1 && cfg[2][4:0]<=16 && cfg[55][15:6]==0 && cfg[55][4:0]>=1 && cfg[55][4:0]<=16 && cfg[3][15:4]==0 && cfg[4][15:9]==0 &&
    (!cfg[4][8] || ((&crc_written) && (&crc_route_valid) && crc_shape_valid)) && (&ext_valid);
  assign pin_oe=live ? cfg[4][2:0] & ~(cfg[4][5:3] & pin_out) &
    ~(temporal_enable ? temporal_oe_gate & {3{!temporal_actions[2]}} : 3'b0) : 0;
  assign pin_out={sink[9],sink[8],sink[7]};
  integer e;
  // Timer words (indices 44-47) have no valid bit; word 56 checks its reserved bits.
  wire [56:0] ext_valid_mask=(ext_index>=44 && ext_index<48) ? 57'b0 : 57'b1 << ext_index[5:0];
  wire [56:0] ext_valid_value={cfg_data[15:2]==0,{56{ext_word_valid}}};
  wire ext_word_valid=ext_index<24 ? cfg_data[15:12]==0 : ext_index<28 ? 1'b1 : cfg_data<=21;
  always @(posedge clk) begin
    if(!rst_n) begin written<=0;crc_written<=0;coder_written<=0;coder_tick_select<=0;coder_tail_required<=0;crc_link_valid<=0;temporal_oe_gate<=0;temporal_oe_gate_valid<=1;context_written<=0;crc_shape_valid<=0;meta<=0;sync<=0;prev<=0;
      ext_valid<={57{1'b1}};seq_enable<=0;seq_select[0]<=0;seq_select[1]<=0;
      for(e=0;e<24;e=e+1) ext_switch[e]<=0;
      for(e=0;e<22;e=e+1) ext_select[e]<=0;
      for(e=0;e<4;e=e+1) begin ext_truth[e]<=0;timer_word[e]<=0;end
    end
    else begin
      meta<=pin_in;sync<=meta;prev<=sync;
      if(!arm && cfg_we && cfg_addr<=62) begin cfg[cfg_addr[5:0]]<=cfg_data;written[cfg_addr[5:0]]<=1;end
      if(!arm && cfg_we && cfg_addr>=112 && cfg_addr<=116) begin
        context_routes[cfg_addr-112]<=cfg_data;context_written[cfg_addr-112]<=1;
      end
      if(!arm && cfg_we && cfg_addr==118) coder_tick_select<=cfg_data[5:0];
      if(!arm && cfg_we && cfg_addr==121) coder_tail_required<=|cfg_data[14:9];
      if(!arm && cfg_we && cfg_addr==123) begin temporal_oe_gate<=cfg_data[2:0];temporal_oe_gate_valid<=cfg_data[15:3]==0;end
      if(!arm && cfg_we && cfg_addr>=117 && cfg_addr<=122) coder_written[cfg_addr-117]<=1;
      if(ext_write) begin
        // One whole-vector update: per-bit writes crash CI's Verilator 5.020 (V3Gate).
        ext_valid<=(ext_valid & ~ext_valid_mask) | (ext_valid_value & ext_valid_mask);
        if(ext_index<24) ext_switch[ext_index[4:0]]<=cfg_data[11:0];
        else if(ext_index<28) ext_truth[ext_index[1:0]]<=cfg_data;
        else if(ext_index>=44 && ext_index<48) timer_word[ext_index[1:0]]<=cfg_data;
        // LUT4 inputs at 156-171, timer 2/3 start/stop/hold at 176-181.
        else if(ext_index<44 || (ext_index>=48 && ext_index<54)) ext_select[select_index]<=cfg_data[4:0];
        else if(ext_index==54 || ext_index==55) seq_select[ext_index[0]]<=cfg_data[4:0];
        else if(ext_index==56) seq_enable<=cfg_data[1:0];
      end
      if(!arm && cfg_we && cfg_addr>=69 && cfg_addr<=80) begin
        crc_written[cfg_addr-69]<=1;
        if(cfg_addr==75) begin crc_shape_valid<=cfg_data[15:7]==0;crc_link_valid<=cfg_data[6];end
        if(cfg_addr>=77) crc_routes[cfg_addr-77]<=cfg_data;
      end
    end
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
  assign local_signal[11]={2'b0,!ble_q[1],ble_q[1]};
  assign local_signal[12]={2'b0,!ble_q[2],ble_q[2]};
  assign local_signal[13]={level3,fall3,rise3,tick3};
  assign local_signal[14]={2'b0,!ble_q[3],ble_q[3]};
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
        ext_switch[(x-9)*4],ext_switch[(x-9)*4+1],ext_switch[(x-9)*4+2],ext_switch[(x-9)*4+3],
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
  fabric_crc crc_tile(clk,rst_n,live && cfg[4][8] && (!packet_mode || packet_running),cfg_we && !arm && cfg_addr>=69 && cfg_addr<=76,
    cfg_addr[2:0]-3'd5,cfg_data,crc_lines,{1'b0,coder_absorb},{1'b0,coder_bit},
    {1'b0,coder_emit},crc_out,crc_tail,crc_ok,crc_value);
  fabric_shifter coded_tile(clk,rst_n,live && packet_mode && packet_running,
    cfg_we && !arm && cfg_addr>=117 && cfg_addr<=122,cfg_addr[2:0]-3'd4,cfg_data,
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
  assign contexts_configured=(&context_written) && (&context_valid) && (&context_unique);
  assign temporal_tick=tick;
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
  fabric_v2_timer timer(clk,rst_n,live,cfg_we && !arm && (cfg_addr==0 || cfg_addr==1),
    cfg_addr==0 ? cfg_data : cfg[0],cfg_addr==1 ? cfg_data : cfg[1],
    sink[0],sink[1],sink[2],tick,running,tvalid,level,rise,fall);
  fabric_v2_shift shifter(clk,rst_n,live,sink[3],sink[4],sink[5],cfg[2][4:0],cfg[2][5],
    tx,sink[6],serial,rx,busy,done);
  fabric_v2_timer timer1(clk,rst_n,live,cfg_we && !arm && (cfg_addr==53 || cfg_addr==54),
    cfg_addr==53 ? cfg_data : cfg[53],cfg_addr==54 ? cfg_data : cfg[54],
    sink[12],sink[13],sink[14],tick1,running1,tvalid1,level1,rise1,fall1);
  fabric_v2_shift shifter1(clk,rst_n,live,sink[15],sink[16],sink[17],cfg[55][4:0],cfg[55][5],
    tx1,sink[18],serial1,rx1,busy1,done1);
  // Extension sinks 19-42 have no alternate-context overrides. Each selector
  // reads constants, its own cell's local outputs or a neighbor's tracks.
  // Sinks: 19-21 timer2, 22-24 timer3, 25-40 LUT4 cells 0-3 inputs a-d,
  // 41-42 sequencer event inputs (in the sequencer's cell 6).
  genvar y;
  generate for(y=19;y<43;y=y+1) begin: ext_inputs
    localparam integer CELL=(y<22)?10:(y<25)?13:(y<29)?9:(y<33)?11:(y<37)?12:(y<41)?14:6;
    wire [4:0] choice=(y>=41) ? seq_select[y-41] : (y<25) ? ext_select[y+16-19] : ext_select[y-25];
    assign sink[y]=route_input({11'b0,choice},local_signal[CELL],n_in[CELL],s_in[CELL],w_in[CELL],e_in[CELL]);
  end endgenerate
  assign seq_events={sink[42],sink[41]};
  assign seq_event_enable=seq_enable;
  fabric_v2_timer timer2(clk,rst_n,live,cfg_we && !arm && (cfg_addr==172 || cfg_addr==173),
    cfg_addr==172 ? cfg_data : timer_word[0],cfg_addr==173 ? cfg_data : timer_word[1],
    sink[19],sink[20],sink[21],tick2,running2,tvalid2,level2,rise2,fall2);
  fabric_v2_timer timer3(clk,rst_n,live,cfg_we && !arm && (cfg_addr==174 || cfg_addr==175),
    cfg_addr==174 ? cfg_data : timer_word[2],cfg_addr==175 ? cfg_data : timer_word[3],
    sink[22],sink[23],sink[24],tick3,running3,tvalid3,level3,rise3,fall3);
  genvar b;
  generate for(b=0;b<4;b=b+1) begin: lut4
    grid_lut4_cell tile(clk,rst_n,live,ext_truth[b],{sink[28+4*b],sink[27+4*b],sink[26+4*b],sink[25+4*b]},ble_q[b]);
  end endgenerate
  wire unused_ext=&{1'b0,running2,tvalid2,running3,tvalid3};
endmodule
`default_nettype wire
