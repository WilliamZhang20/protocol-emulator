`default_nettype none
// 3 x 3 heterogeneous experiment. All route and tile words are loaded while
// disarmed; unlike the preceding fabric there is no global source crossbar.
module grid_core(
  input wire clk,rst_n,arm,cfg_we,
  input wire [5:0] cfg_addr,input wire [15:0] cfg_data,
  input wire trigger,input wire [1:0] pin_in,input wire [15:0] tx,tx1,
  output wire [15:0] rx,rx1,output wire busy,done,busy1,done1,
  output wire [2:0] pin_out,pin_oe,output wire configured);
  reg [15:0] cfg[0:62];
  reg [62:0] written;
  reg [1:0] meta,sync,prev;
  wire [3:0] n_in[0:8],s_in[0:8],w_in[0:8],e_in[0:8];
  wire [3:0] n_out[0:8],s_out[0:8],w_out[0:8],e_out[0:8];
  wire [3:0] local_signal[0:8];
  wire [18:0] sink;
  wire [35:0] switch_valid;
  wire [18:0] sink_valid;
  wire tick,running,tvalid,level,rise,fall,serial;
  wire tick1,running1,tvalid1,level1,rise1,fall1,serial1;
  wire live=arm && rst_n && configured;
  assign configured=(&written) && (&switch_valid) && (&sink_valid) && tvalid && tvalid1 && cfg[2][15:6]==0 && cfg[2][4:0]>=1 && cfg[2][4:0]<=16 && cfg[55][15:6]==0 && cfg[55][4:0]>=1 && cfg[55][4:0]<=16 && cfg[3][15:4]==0 && cfg[4][15:6]==0;
  assign pin_oe=live ? cfg[4][2:0] & ~(cfg[4][5:3] & pin_out) : 0;
  assign pin_out={sink[9],sink[8],sink[7]};
  always @(posedge clk) begin
    if(!rst_n) begin written<=0;meta<=0;sync<=0;prev<=0;end
    else begin
      meta<=pin_in;sync<=meta;prev<=sync;
      if(!arm && cfg_we && cfg_addr<=62) begin cfg[cfg_addr]<=cfg_data;written[cfg_addr]<=1;end
    end
  end
  assign local_signal[0]={prev[1] && !sync[1],prev[0] && !sync[0],sync[1],sync[0]};
  assign local_signal[1]=0;
  assign local_signal[2]={level,fall,rise,tick};
  assign local_signal[3]={serial | !busy,serial,done,busy};
  assign local_signal[4]={3'b0,cfg[3][{2'b00,sink[11],sink[10]}]};
  assign local_signal[5]={level1,fall1,rise1,tick1};
  assign local_signal[6]={3'b0,trigger};
  assign local_signal[7]={serial1 | !busy1,serial1,done1,busy1};
  assign local_signal[8]=0;
  genvar x;
  generate for(x=0;x<9;x=x+1) begin: mesh
    if(x<3) assign n_in[x]=0; else assign n_in[x]=s_out[x-3];
    if(x>=6) assign s_in[x]=0; else assign s_in[x]=n_out[x+3];
    if(x%3==0) assign w_in[x]=0; else assign w_in[x]=e_out[x-1];
    if(x%3==2) assign e_in[x]=0; else assign e_in[x]=w_out[x+1];
    grid_switch sw(n_in[x],s_in[x],w_in[x],e_in[x],local_signal[x],
      cfg[5+x*4][11:0],cfg[6+x*4][11:0],cfg[7+x*4][11:0],cfg[8+x*4][11:0],
      n_out[x],s_out[x],w_out[x],e_out[x]);
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
  // Timer inputs 0..2, shifter inputs 3..6, IO outputs 7..9, LUT inputs 10..11.
  genvar q;
  generate for(q=0;q<19;q=q+1) begin: inputs
    localparam integer CELL=(q<3)?2:(q<7)?3:(q<10)?1:(q<12)?4:(q<15)?5:7;
    localparam integer ADDR=(q<12)?41+q:56+q-12;
    if(q==10 || q==11) begin: logic_feedforward
      // The combinational LUT only takes west-side inputs or constants.
      // This keeps its output from feeding back through programmable routes.
      assign sink_valid[q]=(cfg[ADDR]<=1) || (cfg[ADDR]>=14 && cfg[ADDR]<=17);
      assign sink[q]=(cfg[ADDR]==1) ? 1'b1 :
        ((cfg[ADDR]>=14 && cfg[ADDR]<=17) ? w_in[CELL][cfg[ADDR][1:0]-2'd2] : 1'b0);
    end else begin: regular_input
      assign sink_valid[q]=cfg[ADDR]<=21;
      assign sink[q]=route_input(cfg[ADDR],local_signal[CELL],n_in[CELL],s_in[CELL],w_in[CELL],e_in[CELL]);
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
endmodule
`default_nettype wire
