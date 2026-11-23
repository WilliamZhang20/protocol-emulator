`default_nettype none
// Two timer/shift tiles with independently configured event inputs and pin
// outputs. This standalone candidate is not the Tiny Tapeout top or an SRAM
// adapter. Routes are static while armed and select registered sources.
module fabric_v2(
    input wire clk, rst_n, arm, cfg_we,
    input wire [4:0] cfg_addr, input wire [15:0] cfg_data,
    input wire [1:0] trigger, input wire [1:0] pin_in,
    input wire [15:0] tx0, tx1,
    output wire [2:0] pin_out, pin_oe,
    output wire [15:0] rx0, rx1,
    output wire [1:0] shift_busy, shift_done,
    output wire configured);
  reg [15:0] timer_first[0:1], timer_period[0:1];
  reg [5:0] shift_cfg[0:1];
  reg [4:0] route[0:16];
  reg [23:0] written;
  reg [16:0] route_valid;
  reg [2:0] output_enable;
  reg enable_valid;
  reg [1:0] shift_valid;
  reg [1:0] pin_meta, pin_sync, pin_prev;
  wire [1:0] timer_tick,timer_running,timer_valid,timer_level,timer_rise,timer_fall;
  wire [1:0] serial_out;
  wire [31:0] sources;
  wire live = rst_n && arm && configured;
  assign configured=(&written) && (&route_valid) && (&shift_valid) && (&timer_valid) && enable_valid;
  assign pin_oe=live ? output_enable : 3'b000;
  assign pin_out={sources[route[16]],sources[route[15]],sources[route[14]]};
  assign sources={7'b0,!shift_busy[0],
    pin_prev[1] && !pin_sync[1],pin_prev[0] && !pin_sync[0],
    serial_out[1] | !shift_busy[1],serial_out[1],shift_done[1],shift_busy[1],
    serial_out[0] | !shift_busy[0],serial_out[0],shift_done[0],shift_busy[0],
    timer_level[1],timer_fall[1],timer_rise[1],timer_tick[1],
    timer_level[0],timer_fall[0],timer_rise[0],timer_tick[0],
    pin_sync[1],pin_sync[0],trigger[1],trigger[0],1'b1,1'b0};
  integer i;
  always @(posedge clk) begin
    if (!rst_n) begin
      written<=0; route_valid<=0; shift_valid<=0;output_enable<=0;enable_valid<=0;
      pin_meta<=0;pin_sync<=0;pin_prev<=0;
      for(i=0;i<2;i=i+1) begin timer_first[i]<=0;timer_period[i]<=0;shift_cfg[i]<=0; end
      for(i=0;i<17;i=i+1) route[i]<=0;
    end else begin
      pin_meta<=pin_in;pin_sync<=pin_meta;pin_prev<=pin_sync;
      if (!arm && cfg_we && cfg_addr<22) begin
        written[cfg_addr]<=1'b1;
        case(cfg_addr)
          0: timer_first[0]<=cfg_data;
          1: timer_period[0]<=cfg_data;
          2: timer_first[1]<=cfg_data;
          3: timer_period[1]<=cfg_data;
          4,5: begin
            shift_cfg[cfg_addr-4]<=cfg_data[5:0];
            shift_valid[cfg_addr-4]<=cfg_data[15:6]==0 && cfg_data[4:0]>=1 && cfg_data[4:0]<=16;
          end
          default: begin
            route[cfg_addr-6]<=cfg_data[4:0];
            route_valid[cfg_addr-6]<=cfg_data[15:5]==0 && cfg_data[4:0]<=24;
          end
        endcase
      end
      if (!arm && cfg_we && cfg_addr==24) begin
        written[22]<=1;route[16]<=cfg_data[4:0];
        route_valid[16]<=cfg_data[15:5]==0 && cfg_data[4:0]<=24;
      end
      if (!arm && cfg_we && cfg_addr==25) begin
        written[23]<=1;output_enable<=cfg_data[2:0];enable_valid<=cfg_data[15:3]==0;
      end
    end
  end
  // Revalidate whenever either timer word changes; writes may arrive in any order.
  fabric_v2_timer t0(clk,rst_n,live,cfg_we && !arm && (cfg_addr==0 || cfg_addr==1),
      cfg_addr==0 ? cfg_data : timer_first[0],cfg_addr==1 ? cfg_data : timer_period[0],
      sources[route[0]],sources[route[1]],sources[route[2]],timer_tick[0],timer_running[0],timer_valid[0],timer_level[0],timer_rise[0],timer_fall[0]);
  fabric_v2_timer t1(clk,rst_n,live,cfg_we && !arm && (cfg_addr==2 || cfg_addr==3),
      cfg_addr==2 ? cfg_data : timer_first[1],cfg_addr==3 ? cfg_data : timer_period[1],
      sources[route[3]],sources[route[4]],sources[route[5]],timer_tick[1],timer_running[1],timer_valid[1],timer_level[1],timer_rise[1],timer_fall[1]);
  fabric_v2_shift s0(clk,rst_n,live,sources[route[6]],sources[route[7]],sources[route[8]],
      shift_cfg[0][4:0],shift_cfg[0][5],tx0,sources[route[9]],serial_out[0],rx0,shift_busy[0],shift_done[0]);
  fabric_v2_shift s1(clk,rst_n,live,sources[route[10]],sources[route[11]],sources[route[12]],
      shift_cfg[1][4:0],shift_cfg[1][5],tx1,sources[route[13]],serial_out[1],rx1,shift_busy[1],shift_done[1]);
endmodule
`default_nettype wire
